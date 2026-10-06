module Admin
  # Operator actions on outbound messages. They only write rows and enqueue the
  # send job (Message does the work); Meta is never called from a request.
  class MessagesController < BaseController
    before_action :set_message, only: %i[resend requeue override_window]

    def resend
      respond @message.resend!(by: current_operator), "Message ##{@message.id} queued to send again."
    end

    def requeue
      respond @message.requeue!(by: current_operator), "Message ##{@message.id} requeued; the window is open."
    end

    # An experiment: sends a blocked message although our 24h guard says the
    # window is closed. Meta will most likely refuse it. Needs the confirm box.
    def override_window
      return respond(ActionResult.refused("tick the box to confirm this deliberate test"), nil) unless params[:confirm] == "1"

      respond @message.override_window_send!(by: current_operator),
              "Message ##{@message.id} queued to send outside the 24h window as an experiment."
    end

    # Every failed message of one fixable category, e.g. after replacing a token.
    def resend_failed
      category = params[:category].to_s
      result = Message.resend_failed!(category: category, by: current_operator)
      if result.ok?
        redirect_back_or_to admin_health_path, notice: "#{result.count} failed #{'message'.pluralize(result.count)} (#{category}) queued to send again."
      else
        redirect_back_or_to admin_health_path, alert: "Not done: #{result.reason}"
      end
    end

    private

    def set_message
      @message = Message.outbound.find(params[:id])
    end

    def respond(result, success)
      if result.ok?
        redirect_back_or_to admin_conversation_path(@message.conversation_id), notice: success
      else
        redirect_back_or_to admin_conversation_path(@message.conversation_id), alert: "Not done: #{result.reason}"
      end
    end
  end
end
