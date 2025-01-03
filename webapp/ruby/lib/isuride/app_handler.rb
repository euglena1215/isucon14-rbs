# frozen_string_literal: true

require 'ulid'

require 'isuride/base_handler'
require 'isuride/payment_gateway'

# @rbs generic unchecked out Elem
module Enumerable
  def first! #: Elem
    first || raise('empty')
  end
end

module Isuride
  class AppHandler < BaseHandler
    CurrentUser = Data.define(
      :id, #: String
      :username, #: String
      :firstname, #: String
      :lastname, #: String
      :date_of_birth, #: String
      :access_token, #: String
      :invitation_code, #: String
      :created_at, #: Time
      :updated_at, #: Time
    )

    # @rbs @current_user: CurrentUser

    before do
      if request.path == '/api/app/users'
        next
      end

      access_token = cookies[:app_session]
      if access_token.nil?
        raise HttpError.new(401, 'app_session cookie is required')
      end
      user = db.xquery('SELECT * FROM users WHERE access_token = ?', access_token).first
      if user.nil?
        raise HttpError.new(401, 'invalid access token')
      end

      @current_user = CurrentUser.new(**user) # steep:ignore UnresolvedOverloading
    end

    AppPostUsersRequest = Data.define(
      :username, #: String
      :firstname, #: String
      :lastname, #: String
      :date_of_birth, #: String
      :invitation_code, #: String
    )

    # POST /api/app/users
    post '/users' do
      req = bind_json(AppPostUsersRequest)
      if req.username.nil? || req.firstname.nil? || req.lastname.nil? || req.date_of_birth.nil?
        raise HttpError.new(400, 'required fields(username, firstname, lastname, date_of_birth) are empty')
      end

      user_id = ULID.generate
      access_token = SecureRandom.hex(32)
      invitation_code = SecureRandom.hex(15)

      db_transaction do |tx|
        tx.xquery('INSERT INTO users (id, username, firstname, lastname, date_of_birth, access_token, invitation_code) VALUES (?, ?, ?, ?, ?, ?, ?)', user_id, req.username, req.firstname, req.lastname, req.date_of_birth, access_token, invitation_code)

	      # 初回登録キャンペーンのクーポンを付与
        tx.xquery('INSERT INTO coupons (user_id, code, discount) VALUES (?, ?, ?)', user_id, 'CP_NEW2024', 3000)

	      # 招待コードを使った登録
        unless req.invitation_code.nil? || req.invitation_code.empty?
          # 招待する側の招待数をチェック
          coupons = tx.xquery('SELECT * FROM coupons WHERE code = ? FOR UPDATE', "INV_#{req.invitation_code}").to_a
          if coupons.size >= 3
            raise HttpError.new(400, 'この招待コードは使用できません。')
          end

          # ユーザーチェック
          inviter = tx.xquery('SELECT * FROM users WHERE invitation_code = ?', req.invitation_code).first
          unless inviter
            raise HttpError.new(400, 'この招待コードは使用できません。')
          end

          # 招待クーポン付与
          tx.xquery('INSERT INTO coupons (user_id, code, discount) VALUES (?, ?, ?)', user_id, "INV_#{req.invitation_code}", 1500)
          # 招待した人にもRewardを付与
          tx.xquery("INSERT INTO coupons (user_id, code, discount) VALUES (?, CONCAT(?, '_', FLOOR(UNIX_TIMESTAMP(NOW(3))*1000)), ?)", inviter.fetch(:id), "RWD_#{req.invitation_code}", 1000)
        end
      end

      cookies.set(:app_session, httponly: false, value: access_token, path: '/')
      status(201)
      json(id: user_id, invitation_code:)
    end

    AppPostPaymentMethodsRequest = Data.define(
      :token #: String?
    )

    # POST /api/app/payment-methods
    post '/payment-methods' do
      req = bind_json(AppPostPaymentMethodsRequest)
      if req.token.nil?
        raise HttpError.new(400, 'token is required but was empty')
      end

      db.xquery('INSERT INTO payment_tokens (user_id, token) VALUES (?, ?)', @current_user.id, req.token)

      status(204)
    end

    # GET /api/app/rides
    get '/rides' do
      items = db_transaction do |tx|
        rides = tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC', @current_user.id)

        rides.filter_map do |ride|
          ride_id = ride.fetch(:id)
          raise unless ride_id.is_a?(String)
          status = get_latest_ride_status(tx, ride_id)
          if status != 'COMPLETED'
            next
          end

          ride_created_at = ride.fetch(:created_at)
          ride_updated_at = ride.fetch(:updated_at)
          raise unless ride_created_at.is_a?(Time)
          raise unless ride_updated_at.is_a?(Time)

          ride_pickup_latitude = ride.fetch(:pickup_latitude)
          ride_pickup_longitude = ride.fetch(:pickup_longitude)
          ride_dest_latitude = ride.fetch(:destination_latitude)
          ride_dest_longitude = ride.fetch(:destination_longitude)
          raise unless ride_pickup_latitude.is_a?(Integer)
          raise unless ride_pickup_longitude.is_a?(Integer)
          raise unless ride_dest_latitude.is_a?(Integer)
          raise unless ride_dest_longitude.is_a?(Integer)

          fare = calculate_discounted_fare(tx, @current_user.id, ride, ride_pickup_latitude, ride_pickup_longitude, ride_dest_latitude, ride_dest_latitude)

          chair = tx.xquery('SELECT * FROM chairs WHERE id = ?', ride.fetch(:chair_id)).first!
          owner = tx.xquery('SELECT * FROM owners WHERE id = ?', chair.fetch(:owner_id)).first!

          {
            id: ride.fetch(:id),
            pickup_coordinate: {
              latitude: ride.fetch(:pickup_latitude),
              longitude: ride.fetch(:pickup_longitude),
            },
            destination_coordinate: {
              latitude: ride.fetch(:destination_latitude),
              longitude: ride.fetch(:destination_longitude),
            },
            fare:,
            evaluation: ride.fetch(:evaluation),
            requested_at: time_msec(ride_created_at),
            completed_at: time_msec(ride_updated_at),
            chair: {
              id: chair.fetch(:id),
              name: chair.fetch(:name),
              model: chair.fetch(:model),
              owner: owner.fetch(:name),
            },
          }
        end
      end

      json(rides: items)
    end

    Coordinate = Data.define(
      :latitude, #: Integer
      :longitude #: Integer
    )

    AppPostRidesRequest = Data.define(:pickup_coordinate, :destination_coordinate)
    class AppPostRidesRequest
      # @rbs (pickup_coordinate: Hash[Symbol, untyped], destination_coordinate: Hash[Symbol, untyped], **untyped) -> void
      def initialize(pickup_coordinate:, destination_coordinate:, **kwargs)
        # やっぱりオープンクラスで参照する super は steep で正しく評価するのは難しそう
        super(
          pickup_coordinate: Coordinate.new(**pickup_coordinate), # steep:ignore
          destination_coordinate: Coordinate.new(**destination_coordinate), # steep:ignore
          **kwargs,
        )
      end
    end

    # POST /api/app/rides
    post '/rides' do
      req = bind_json(AppPostRidesRequest)
      if req.pickup_coordinate.nil? || req.destination_coordinate.nil?
        raise HttpError.new(400, 'required fields(pickup_coordinate, destination_coordinate) are empty')
      end

      ride_id = ULID.generate

      fare = db_transaction do |tx|
        rides = tx.xquery('SELECT * FROM rides WHERE user_id = ?', @current_user.id).to_a

        continuing_ride_count = rides.count do |ride|
          rid = ride.fetch(:id)
          raise unless rid.is_a?(String)
          status = get_latest_ride_status(tx, rid)
          status != 'COMPLETED'
        end

        if continuing_ride_count > 0
          raise HttpError.new(429, 'ride already exists')
        end

        tx.xquery(
          'INSERT INTO rides (id, user_id, pickup_latitude, pickup_longitude, destination_latitude, destination_longitude) VALUES (?, ?, ?, ?, ?, ?)',
          ride_id,
          @current_user.id,
          req.pickup_coordinate.latitude,
          req.pickup_coordinate.longitude,
          req.destination_coordinate.latitude,
          req.destination_coordinate.longitude,
        )

        tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride_id, 'MATCHING')

        ride_count = tx.xquery('SELECT COUNT(*) FROM rides WHERE user_id = ?', @current_user.id, as: :array).first![0]

        if ride_count == 1
          # 初回利用で、初回利用クーポンがあれば必ず使う
          coupon = tx.xquery("SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL FOR UPDATE", @current_user.id).first
          if coupon.nil?
            # 無ければ他のクーポンを付与された順番に使う
            coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE', @current_user.id).first
            unless coupon.nil?
              tx.xquery('UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = ?', ride_id, @current_user.id, coupon.fetch(:code))
            end
          else
            tx.xquery("UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = 'CP_NEW2024'", ride_id, @current_user.id)
          end
        else
          # 他のクーポンを付与された順番に使う
          coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE', @current_user.id).first
          unless coupon.nil?
            tx.xquery('UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = ?', ride_id, @current_user.id, coupon.fetch(:code))
          end
        end

        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first

        calculate_discounted_fare(tx, @current_user.id, ride, req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude)
      end

      status(202)
      json(ride_id:, fare:)
    end

    AppPostRidesEstimatedFareRequest = Data.define(
      :pickup_coordinate, #: Coordinate?
      :destination_coordinate #: Coordinate?
    )
    class AppPostRidesEstimatedFareRequest
      # @rbs (pickup_coordinate: Hash[Symbol, untyped], destination_coordinate: Hash[Symbol, untyped], **untyped) -> void
      def initialize(pickup_coordinate:, destination_coordinate:, **kwargs)
        # オープンクラスの super が正しく評価できてない
        super(
          pickup_coordinate: (Coordinate.new(**pickup_coordinate) unless pickup_coordinate.nil?), # steep:ignore
          destination_coordinate: (Coordinate.new(**destination_coordinate) unless destination_coordinate.nil?), # steep:ignore
          **kwargs,
        )
      end
    end

    # POST /api/app/rides/estimated-fare
    post '/rides/estimated-fare' do
      req = bind_json(AppPostRidesEstimatedFareRequest)
      if req.pickup_coordinate.nil? || req.destination_coordinate.nil?
        raise HttpError.new(400, 'required fields(pickup_coordinate, destination_coordinate) are empty')
      end

      discounted = db_transaction do |tx|
        calculate_discounted_fare(tx, @current_user.id, nil, req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude)
      end

      json(
        fare: discounted,
        discount: calculate_fare(req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude) - discounted,
      )
    end

    AppPostRideEvaluationRequest = Data.define(
      :evaluation #: Integer
    )

    # POST /api/app/rides/:ride_id/evaluation
    post '/rides/:ride_id/evaluation' do
      ride_id = params[:ride_id]

      req = bind_json(AppPostRideEvaluationRequest)
      if req.evaluation < 1 || req.evaluation > 5
        raise HttpError.new(400, 'evaluation must be between 1 and 5')
      end

      response = db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.nil?
          raise HttpError.new(404, 'ride not found')
        end
        rid = ride.fetch(:id)
        raise unless rid.is_a?(String)
        status = get_latest_ride_status(tx, rid)

        if status != 'ARRIVED'
          raise HttpError.new(400, 'not arrived yet')
        end

        tx.xquery('UPDATE rides SET evaluation = ? WHERE id = ?', req.evaluation, ride_id)
        if tx.affected_rows == 0
          raise HttpError.new(404, 'ride not found')
        end

        tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride_id, 'COMPLETED')

        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.nil?
          raise HttpError.new(404, 'ride not found')
        end

        payment_token = tx.xquery('SELECT * FROM payment_tokens WHERE user_id = ?', ride.fetch(:user_id)).first
        if payment_token.nil?
          raise HttpError.new(400, 'payment token not registered')
        end

        r_uid = ride.fetch(:user_id)
        r_pickup_lat = ride.fetch(:pickup_latitude)
        r_pickup_lng = ride.fetch(:pickup_longitude)
        r_dest_lat = ride.fetch(:destination_latitude)
        r_dest_lng = ride.fetch(:destination_longitude)
        raise unless r_uid.is_a?(String)
        raise unless r_pickup_lat.is_a?(Integer)
        raise unless r_pickup_lng.is_a?(Integer)
        raise unless r_dest_lat.is_a?(Integer)
        raise unless r_dest_lng.is_a?(Integer)

        fare = calculate_discounted_fare(tx, r_uid, ride, r_pickup_lat, r_pickup_lng, r_dest_lat, r_dest_lng)

        payment_gateway_url = tx.query("SELECT value FROM settings WHERE name = 'payment_gateway_url'").first!.fetch(:value)
        raise unless payment_gateway_url.is_a?(String)
        token = payment_token.fetch(:token)
        raise unless token.is_a?(String)

        begin
          PaymentGateway.new(payment_gateway_url, token).request_post_payment(amount: fare) do
            tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at ASC', ride.fetch(:user_id))
          end
        rescue PaymentGateway::ErroredUpstream => e
          raise HttpError.new(502, e.message)
        end

        r_updated_at = ride.fetch(:updated_at)
        raise unless r_updated_at.is_a?(Time)

        {
          completed_at: time_msec(r_updated_at),
        }
      end

      json(response)
    end

    # GET /api/app/notification
    get '/notification' do
      response = db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC LIMIT 1', @current_user.id).first
        if ride.nil?
          halt json(data: nil, retry_after_ms: 30)
          raise
        end

        r_id = ride.fetch(:id)
        raise unless r_id.is_a?(String)
        r_pickup_lat = ride.fetch(:pickup_latitude)
        raise unless r_pickup_lat.is_a?(Integer)
        r_pickup_lng = ride.fetch(:pickup_longitude)
        raise unless r_pickup_lng.is_a?(Integer)
        r_dest_lat = ride.fetch(:destination_latitude)
        raise unless r_dest_lat.is_a?(Integer)
        r_dest_lng = ride.fetch(:destination_longitude)
        raise unless r_dest_lng.is_a?(Integer)
        r_created_at = ride.fetch(:created_at)
        raise unless r_created_at.is_a?(Time)
        r_updated_at = ride.fetch(:updated_at)
        raise unless r_updated_at.is_a?(Time)

        yet_sent_ride_status = tx.xquery('SELECT * FROM ride_statuses WHERE ride_id = ? AND app_sent_at IS NULL ORDER BY created_at ASC LIMIT 1', ride.fetch(:id)).first
        status =
          if yet_sent_ride_status.nil?
            get_latest_ride_status(tx, r_id)
          else
            yet_sent_ride_status.fetch(:status)
          end

        fare = calculate_discounted_fare(tx, @current_user.id, ride, r_pickup_lat, r_pickup_lng, r_dest_lat, r_dest_lng)

        response = {
          data: {
            ride_id: ride.fetch(:id),
            pickup_coordinate: {
              latitude: ride.fetch(:pickup_latitude),
              longitude: ride.fetch(:pickup_longitude),
            },
            destination_coordinate: {
              latitude: ride.fetch(:destination_latitude),
              longitude: ride.fetch(:destination_longitude),
            },
            fare:,
            status:,
            created_at: time_msec(r_created_at),
            updated_at: time_msec(r_updated_at),
          },
          retry_after_ms: 30,
        }

        unless ride.fetch(:chair_id).nil?
          chair = tx.xquery('SELECT * FROM chairs WHERE id = ?', ride.fetch(:chair_id)).first!
          c_id = chair.fetch(:id)
          raise unless c_id.is_a?(String)
          stats = get_chair_stats(tx, c_id)
          # ここで response の型が
          # `(::Hash[::Symbol, (::Mysql2::row_value_type | ::Hash[::Symbol, ::Mysql2::row_value_type] | ::Integer)] | ::Integer)`
          # になってるのは何かがおかしそう。373行目の response を定義しようとしているのが原因なのかな
          response[:data][:chair] = { # steep:ignore NoMethod
            id: chair.fetch(:id),
            name: chair.fetch(:name),
            model: chair.fetch(:model),
            stats:,
          }
        end

        unless yet_sent_ride_status.nil?
          tx.xquery('UPDATE ride_statuses SET app_sent_at = CURRENT_TIMESTAMP(6) WHERE id = ?', yet_sent_ride_status.fetch(:id))
        end

        response
      end

      json(response)
    end

    # GET /api/app/nearby-chairs
    get '/nearby-chairs' do
      lat_str = params[:latitude]
      lon_str = params[:longitude]
      distance_str = params[:distance]
      if lat_str.nil? || lon_str.nil?
        raise HttpError.new(400, 'latitude or longitude is empty')
      end

      latitude =
        begin
          Integer(lat_str, 10)
        rescue
          raise HttpError.new(400, 'latitude is invalid')
        end

      longitude =
        begin
          Integer(lon_str, 10)
        rescue
          raise HttpError.new(400, 'longitude is invalid')
        end

      distance =
        if distance_str.nil?
          50
        else
          begin
            Integer(distance_str, 10)
          rescue
            raise HttpError.new(400, 'distance is invalid')
          end
        end

      response = db_transaction do |tx|
        chairs = tx.query('SELECT * FROM chairs')

        nearby_chairs = chairs.filter_map do |chair|
          unless chair.fetch(:is_active)
            next
          end

          rides = tx.xquery('SELECT * FROM rides WHERE chair_id = ? ORDER BY created_at DESC LIMIT 1', chair.fetch(:id))

          skip = false
          rides.each do |ride|
            r_id = ride.fetch(:id)
            raise unless r_id.is_a?(String)
            # 過去にライドが存在し、かつ、それが完了していない場合はスキップ
            status = get_latest_ride_status(tx, r_id)
            if status != 'COMPLETED'
              skip = true
              break
            end
          end
          if skip
            next
          end

          # 最新の位置情報を取得
          chair_location = tx.xquery('SELECT * FROM chair_locations WHERE chair_id = ? ORDER BY created_at DESC LIMIT 1', chair.fetch(:id)).first
          if chair_location.nil?
            next
          end

          cl_lat = chair_location.fetch(:latitude)
          raise unless cl_lat.is_a?(Integer)
          cl_lng = chair_location.fetch(:longitude)
          raise unless cl_lng.is_a?(Integer)
          if calculate_distance(latitude, longitude, cl_lat, cl_lng) <= distance
            {
              id: chair.fetch(:id),
              name: chair.fetch(:name),
              model: chair.fetch(:model),
              current_coordinate: {
                latitude: chair_location.fetch(:latitude),
                longitude: chair_location.fetch(:longitude),
              },
            }
          end
        end

        retrieved_at = tx.query('SELECT CURRENT_TIMESTAMP(6)', as: :array).first![0]
        raise unless retrieved_at.is_a?(Time)

        {
          chairs: nearby_chairs,
          retrieved_at: time_msec(retrieved_at),
        }
      end

      json(response)
    end

    helpers do
      # @rbs (Mysql2::Client[::Mysql2::ResultAsHash], String) -> { total_rides_count: Integer, total_evaluation_avg: Float }
      def get_chair_stats(tx, chair_id)
        rides = tx.xquery('SELECT * FROM rides WHERE chair_id = ? ORDER BY updated_at DESC', chair_id)

        total_rides_count = 0
        total_evaluation = 0.0
        rides.each do |ride|
          ride_statuses = tx.xquery('SELECT * FROM ride_statuses WHERE ride_id = ? ORDER BY created_at', ride.fetch(:id))

          arrived_at = nil #: Time?
          pickup_at = nil #: Time?
          is_completed = false
          ride_statuses.each do |status|
            case status.fetch(:status)
            when 'ARRIVED'
              status_created_at = status.fetch(:created_at)
              raise unless status_created_at.is_a?(Time)
              arrived_at = status_created_at
            when 'CARRYING'
              status_created_at = status.fetch(:created_at)
              raise unless status_created_at.is_a?(Time)
              pickup_at = status_created_at
            when 'COMPLETED'
              is_completed = true
            end
          end
          if arrived_at.nil? || pickup_at.nil?
            next
          end
          unless is_completed
            next
          end

          total_rides_count += 1
          evaluation = ride.fetch(:evaluation)
          raise unless evaluation.is_a?(Integer)
          total_evaluation += evaluation
        end

        total_evaluation_avg =
          if total_rides_count > 0
            total_evaluation / total_rides_count
          else
            0.0
          end

        {
          total_rides_count:,
          total_evaluation_avg:,
        }
      end

      # @rbs (Mysql2::Client[::Mysql2::ResultAsHash], String, Hash[Symbol, untyped]?, Integer, Integer, Integer, Integer) -> Integer
      def calculate_discounted_fare(tx, user_id, ride, pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        discount =
          if !ride.nil?
            dest_latitude = ride.fetch(:destination_latitude)
            dest_longitude = ride.fetch(:destination_longitude)
            pickup_latitude = ride.fetch(:pickup_latitude)
            pickup_longitude = ride.fetch(:pickup_longitude)

            # すでにクーポンが紐づいているならそれの割引額を参照
            coupon = tx.xquery('SELECT * FROM coupons WHERE used_by = ?', ride.fetch(:id)).first
            if coupon.nil?
              0
            else
              coupon.fetch(:discount)
            end
          else
            # 初回利用クーポンを最優先で使う
            coupon = tx.xquery("SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL", user_id).first
            if coupon.nil?
              # 無いなら他のクーポンを付与された順番に使う
              coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1', user_id).first
              if coupon.nil?
                0
              else
                coupon.fetch(:discount)
              end
            else
              coupon.fetch(:discount)
            end
          end #: Integer

        metered_fare = FARE_PER_DISTANCE * calculate_distance(pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        discounted_metered_fare = [metered_fare - discount, 0].max

        INITIAL_FARE + discounted_metered_fare
      end
    end
  end
end
