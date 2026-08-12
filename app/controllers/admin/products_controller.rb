module Admin
  class ProductsController < ApplicationController
    def index
      @products = Product.includes(:category).order("categories.position, products.name").references(:category)
    end
  end
end
