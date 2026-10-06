module Admin
  class OrdersController < BaseController
    def index
      @orders = Order.includes(:customer, order_items: :product).order(created_at: :desc, id: :desc)
    end

    def show
      @order = Order.includes(:customer, order_items: :product).find(params[:id])
    end
  end
end
