module Admin
  class OrdersController < ApplicationController
    def index
      @orders = Order.includes(:customer, order_items: :product)
    end

    def show
      @order = Order.includes(:customer, order_items: :product).find(params[:id])
    end
  end
end
