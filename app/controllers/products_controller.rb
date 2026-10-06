# Simple public product page. Required as the feed's `link` field even
# though the WhatsApp Catalog UI renders its own native card — this page is
# what a customer would land on if they tapped through from outside WhatsApp.
class ProductsController < ApplicationController
  def index
    @categories = Category.on_menu.includes(:menu_products)
  end

  def show
    @product = Product.non_synthetic.find(params[:id])
  end
end
