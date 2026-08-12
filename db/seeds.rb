# Seed data for "The Local Table" — a demo restaurant used to exercise the
# WhatsApp native Catalog + Cart flow. Names and dishes are real, photos are
# real (sourced from TheMealDB / TheCocktailDB's free public APIs), but the
# restaurant itself is fictional — built for this demo only.
#
# Idempotent: safe to run repeatedly (`bin/rails db:seed`).

CATALOG = {
  "Starters" => {
    slug: "starters",
    position: 0,
    items: [
      { name: "Black Bean Soup", sku: "STR-001", price: 7.50,
        description: "A hearty Cuban-style black bean soup, simmered with garlic, cumin and a squeeze of lime.",
        image_url: "https://www.themealdb.com/images/media/meals/x0mreq1784577446.jpg" },
      { name: "Broccoli & Stilton Soup", sku: "STR-002", price: 7.00,
        description: "Classic British soup pairing fresh broccoli with sharp, creamy Stilton.",
        image_url: "https://www.themealdb.com/images/media/meals/tvvxpv1511191952.jpg" },
      { name: "New England Clam Chowder", sku: "STR-003", price: 8.50,
        description: "Creamy chowder loaded with clams, potatoes and smoky bacon.",
        image_url: "https://www.themealdb.com/images/media/meals/rvtvuw1511190488.jpg" },
      { name: "Baked Brie with Sorrel Jam", sku: "STR-004", price: 9.50,
        description: "Warm baked brie topped with a tangy-sweet sorrel jam, served with crusty bread.",
        image_url: "https://www.themealdb.com/images/media/meals/fg7d641784666908.jpg" },
      { name: "Creamy Tomato Soup", sku: "STR-005", price: 7.00,
        description: "Slow-simmered vine tomatoes blended smooth with cream and fresh basil.",
        image_url: "https://www.themealdb.com/images/media/meals/stpuws1511191310.jpg" }
    ]
  },
  "Mains" => {
    slug: "mains",
    position: 1,
    items: [
      { name: "Brown Stew Chicken", sku: "MAI-001", price: 16.50,
        description: "Jamaican-style chicken braised low and slow in a rich brown stew sauce.",
        image_url: "https://www.themealdb.com/images/media/meals/sypxpx1515365095.jpg" },
      { name: "Bengali Chicken Curry with Potatoes", sku: "MAI-002", price: 17.00,
        description: "Fragrant, spiced chicken curry with tender potatoes, served with steamed rice.",
        image_url: "https://www.themealdb.com/images/media/meals/9ya6o71780262651.jpg" },
      { name: "Chicken & Mushroom Hotpot", sku: "MAI-003", price: 16.00,
        description: "Comforting one-pot chicken and wild mushroom stew with a crisp potato topping.",
        image_url: "https://www.themealdb.com/images/media/meals/uuuspp1511297945.jpg" },
      { name: "Baked Salmon with Fennel & Tomatoes", sku: "MAI-004", price: 19.50,
        description: "Oven-roasted salmon fillet over braised fennel and cherry tomatoes.",
        image_url: "https://www.themealdb.com/images/media/meals/1548772327.jpg" },
      { name: "Fettuccine Alfredo", sku: "MAI-005", price: 15.00,
        description: "Fresh fettuccine tossed in a silky Parmesan cream sauce.",
        image_url: "https://www.themealdb.com/images/media/meals/0jv5gx1661040802.jpg" },
      { name: "Classic Lasagne", sku: "MAI-006", price: 15.50,
        description: "Layers of pasta, slow-cooked ragù and béchamel, baked until golden.",
        image_url: "https://www.themealdb.com/images/media/meals/wtsvxx1511296896.jpg" }
    ]
  },
  "Desserts" => {
    slug: "desserts",
    position: 2,
    items: [
      { name: "Apple & Blackberry Crumble", sku: "DES-001", price: 7.50,
        description: "Warm spiced apples and blackberries under a buttery oat crumble, best with custard.",
        image_url: "https://www.themealdb.com/images/media/meals/xvsurr1511719182.jpg" },
      { name: "Apple Pie", sku: "DES-002", price: 6.50,
        description: "A flaky double-crust pie filled with cinnamon-spiced apples.",
        image_url: "https://www.themealdb.com/images/media/meals/stnxzp1784835840.jpg" },
      { name: "Anzac Biscuits", sku: "DES-003", price: 5.00,
        description: "Chewy oat and golden-syrup biscuits, an Australian classic.",
        image_url: "https://www.themealdb.com/images/media/meals/q47rkb1762324620.jpg" },
      { name: "Dutch Apple Cake", sku: "DES-004", price: 6.50,
        description: "Moist spiced apple cake with a tender buttery crumb.",
        image_url: "https://www.themealdb.com/images/media/meals/c0gmo31766594751.jpg" },
      { name: "Apple Frangipan Tart", sku: "DES-005", price: 7.00,
        description: "Almond frangipane and thin apple slices baked in a shortcrust shell.",
        image_url: "https://www.themealdb.com/images/media/meals/wxywrq1468235067.jpg" }
    ]
  },
  "Beverages" => {
    slug: "beverages",
    position: 3,
    items: [
      { name: "Aloha Fruit Punch", sku: "BEV-001", price: 4.50,
        description: "A tropical, non-alcoholic blend of pineapple, orange and grenadine.",
        image_url: "https://www.thecocktaildb.com/images/media/drink/wsyvrt1468876267.jpg" },
      { name: "Apple Berry Smoothie", sku: "BEV-002", price: 5.00,
        description: "Apple juice blended with mixed berries and yogurt.",
        image_url: "https://www.thecocktaildb.com/images/media/drink/xwqvur1468876473.jpg" },
      { name: "Banana Milk Shake", sku: "BEV-003", price: 4.50,
        description: "Classic thick banana milkshake, blended fresh.",
        image_url: "https://www.thecocktaildb.com/images/media/drink/rtwwsx1472720307.jpg" },
      { name: "Cranberry Punch", sku: "BEV-004", price: 4.00,
        description: "Refreshing cranberry and citrus punch, served chilled.",
        image_url: "https://www.thecocktaildb.com/images/media/drink/mzgaqu1504389248.jpg" }
    ]
  }
}.freeze

CATALOG.each do |category_name, data|
  category = Category.find_or_create_by!(slug: data[:slug]) do |c|
    c.name = category_name
    c.position = data[:position]
  end
  category.update!(name: category_name, position: data[:position])

  data[:items].each do |item|
    product = Product.find_or_initialize_by(sku: item[:sku])
    product.assign_attributes(
      name: item[:name],
      description: item[:description],
      price_cents: (item[:price] * 100).round,
      currency: "USD",
      image_url: item[:image_url],
      availability: :in_stock,
      category: category
    )
    product.save!
  end
end

puts "Seeded #{Category.count} categories and #{Product.count} menu items for The Local Table."

# A couple of demo customers/conversations so the admin views aren't empty
# before the first real WhatsApp message arrives.
demo_customer = Customer.find_or_create_by!(whatsapp_number: "+15551234567") do |c|
  c.display_name = "Jordan (demo)"
end
demo_customer.create_conversation! unless demo_customer.conversation

puts "Seeded #{Customer.count} demo customer(s)."
