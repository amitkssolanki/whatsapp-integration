module Admin
  class ProductsController < BaseController
    def index
      @products = Product.includes(:category).order("categories.position, products.name").references(:category)
    end
  end
end
