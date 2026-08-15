class ErrorsController < ActionController::Base
  layout "application"

  skip_forgery_protection

  def bad_request
    render status: :bad_request
  end

  def not_found
    if request.path.start_with?("/api")
      render json: { error: "Not found." }, status: :not_found
    else
      render status: :not_found
    end
  end

  def unprocessable_entity
    render status: :unprocessable_entity
  end

  def internal_server_error
    exception = request.env["action_dispatch.exception"]
    error_id = SecureRandom.hex(4).upcase

    if exception
      Appsignal.set_error(exception)
      Appsignal.add_tags(error_id: error_id)
      Rails.logger.error("[#{error_id}] #{exception.class}: #{exception.message}")
    end

    render status: :internal_server_error, locals: { error_id: error_id }
  end
end
