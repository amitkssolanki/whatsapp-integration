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
