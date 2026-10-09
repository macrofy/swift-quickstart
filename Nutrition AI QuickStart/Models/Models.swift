import Foundation

// MARK: - Auth Models

public nonisolated struct ConnectRequest: Codable, Sendable {
    public let appId: String
    public let userId: String
    public let signature: String

    public init(appId: String, userId: String, signature: String) {
        self.appId = appId
        self.userId = userId
        self.signature = signature
    }
}

public nonisolated struct SessionUser: Codable, Equatable, Sendable {
    /// Internal Macrofy UUID for this external user
    public let id: String
    /// Tenant Application ID
    public let appId: String
    /// Developer external user ID
    public let externalId: String
}

public nonisolated struct AuthResponse: Codable, Sendable {
    public let token: String
    public let user: SessionUser
}

// MARK: - Food & Nutrition Models

public nonisolated struct ServingSize: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: String
    public let label: String?
}

// `macrofy_products.calories100g/protein100g/carbs100g/fat100g/fiber100g/
// sugars100g/sodium100g` are all nullable columns (no NOT NULL constraint in
// postgres_schema.sql), so every field here must be optional — a product
// with incomplete nutrition data would otherwise fail to decode entirely.
public nonisolated struct Macros: Codable, Equatable, Sendable {
    public let energy: Double? // kcal
    public let protein: Double? // grams
    public let fat: Double? // grams
    public let carbohydrates: Double? // grams
    public let fiber: Double?
    public let sugar: Double?
    public let sodium: Double? // milligrams
}

public nonisolated struct FoodItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let brand: String?
    // macrofy_products.barcode is NOT NULL.
    public let barcode: String
    // macrofy_products.serving_size_grams/serving_label/serving_size_raw are
    // all nullable, so a product can have no serving size info at all.
    public let servingSize: ServingSize?
    public let macros: Macros
    public let macrosPer100g: Macros?
    public let source: String
    public let ingredients: String?
    public let allergens: String?
    public let createdAt: String // ISO-8601 string
    public let updatedAt: String // ISO-8601 string
}

// MARK: - AI Scan Models

public nonisolated struct CreateScanJobRequest: Codable, Sendable {
    public let contentType: String
    public let imageType: String

    public init(contentType: String = "image/jpeg", imageType: String = "photo") {
        self.contentType = contentType
        self.imageType = imageType
    }
}

public nonisolated struct CreateScanJobResponse: Codable, Sendable {
    public let jobId: String
    public let uploadUrl: String
}

public nonisolated struct ScanIngredient: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let servingSize: Double
    public let unit: String
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
}

public nonisolated struct ScanFoodResult: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let servingSize: Double?
    public let brand: String?
    public let source: String?
    public let ingredients: [ScanIngredient]?
}

public nonisolated struct ImageScanStatusUpdate: Codable, Sendable {
    public let jobId: String
    public let status: String // "processing", "completed", "failed"
    public let resultUrl: String?
    public let result: ScanFoodResult?
    public let errorMessage: String?
}

// MARK: - User Profile & Goal Models

public nonisolated enum Gender: String, Codable, Sendable {
    case male
    case female
    case other
}

public nonisolated enum ActivityLevel: String, Codable, Sendable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive = "very_active"
}

public nonisolated enum CalorieDeficit: String, Codable, Sendable {
    case lose025 = "lose_0_25"
    case lose05 = "lose_0_5"
    case lose075 = "lose_0_75"
    case lose1 = "lose_1"
    case lose15 = "lose_1_5"
    case lose2 = "lose_2"
    case maintain
    case gain025 = "gain_0_25"
    case gain05 = "gain_0_5"
    case gain075 = "gain_0_75"
    case gain1 = "gain_1"
    case gain15 = "gain_1_5"
    case gain2 = "gain_2"
}

public nonisolated enum DietType: String, Codable, Sendable {
    case balanced
    case lowCarb = "low_carb"
    case highProtein = "high_protein"
    case keto
}

/// A paired imperial height measurement.
///
/// `user_profiles.height_cm` is stored server-side as a single integer
/// column (see `postgres_schema.sql`); the API's client-facing
/// `heightFeet`/`heightInches` fields are just an imperial view of that one
/// value. Because a partial pair (only feet, or only inches) can never be
/// converted to a valid centimeter value, the API rejects it — representing
/// height as one paired type here (instead of two independent optionals)
/// makes it impossible to construct or encode a half-complete height.
public nonisolated struct HeightImperial: Equatable, Sendable {
    public let feet: Int
    public let inches: Int

    public init(feet: Int, inches: Int) {
        self.feet = feet
        self.inches = inches
    }
}

/// Represents a field in a PUT/PATCH update request.
/// - `.unchanged`: the key is omitted entirely from the encoded JSON, leaving the server's existing value unchanged.
/// - `.set(value)`: the key is encoded as `"key": value`.
/// - `.clear`: the key is explicitly encoded as `"key": null`, telling the server to clear the field.
public nonisolated enum NullableUpdate<Value: Sendable>: Sendable, Equatable where Value: Equatable {
    case unchanged
    case set(Value)
    case clear
}

public nonisolated struct UserProfile: Codable, Equatable, Sendable {
    public let userId: String
    // user_profiles.name is nullable.
    public let name: String?
    public let age: Int?
    public let gender: Gender?
    /// Paired `heightFeet`/`heightInches` from the API, or `nil` if neither
    /// was set. See `HeightImperial`.
    public let height: HeightImperial?
    public let weight: Int? // Imperial lbs
    public let activityLevel: ActivityLevel?
    public let calorieDeficit: CalorieDeficit?
    public let dietType: DietType?
    public let waterLevel: Int? // ml
    // user_profiles.updated_at is NOT NULL (defaults to now()).
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case userId, name, age, gender, weight
        case heightFeet, heightInches
        case activityLevel, calorieDeficit, dietType, waterLevel, updatedAt
    }

    public init(
        userId: String,
        name: String? = nil,
        age: Int? = nil,
        gender: Gender? = nil,
        height: HeightImperial? = nil,
        weight: Int? = nil,
        activityLevel: ActivityLevel? = nil,
        calorieDeficit: CalorieDeficit? = nil,
        dietType: DietType? = nil,
        waterLevel: Int? = nil,
        updatedAt: String
    ) {
        self.userId = userId
        self.name = name
        self.age = age
        self.gender = gender
        self.height = height
        self.weight = weight
        self.activityLevel = activityLevel
        self.calorieDeficit = calorieDeficit
        self.dietType = dietType
        self.waterLevel = waterLevel
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        age = try container.decodeIfPresent(Int.self, forKey: .age)
        gender = try container.decodeIfPresent(Gender.self, forKey: .gender)
        if let feet = try container.decodeIfPresent(Int.self, forKey: .heightFeet),
           let inches = try container.decodeIfPresent(Int.self, forKey: .heightInches) {
            height = HeightImperial(feet: feet, inches: inches)
        } else {
            // A response with only one of the two fields set is treated as
            // "no height data" rather than failing the whole decode.
            height = nil
        }
        weight = try container.decodeIfPresent(Int.self, forKey: .weight)
        activityLevel = try container.decodeIfPresent(ActivityLevel.self, forKey: .activityLevel)
        calorieDeficit = try container.decodeIfPresent(CalorieDeficit.self, forKey: .calorieDeficit)
        dietType = try container.decodeIfPresent(DietType.self, forKey: .dietType)
        waterLevel = try container.decodeIfPresent(Int.self, forKey: .waterLevel)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(age, forKey: .age)
        try container.encodeIfPresent(gender, forKey: .gender)
        try container.encodeIfPresent(height?.feet, forKey: .heightFeet)
        try container.encodeIfPresent(height?.inches, forKey: .heightInches)
        try container.encodeIfPresent(weight, forKey: .weight)
        try container.encodeIfPresent(activityLevel, forKey: .activityLevel)
        try container.encodeIfPresent(calorieDeficit, forKey: .calorieDeficit)
        try container.encodeIfPresent(dietType, forKey: .dietType)
        try container.encodeIfPresent(waterLevel, forKey: .waterLevel)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public nonisolated struct DailyGoals: Codable, Equatable, Sendable {
    public let calories: Int
    public let carbs: Int // grams
    public let protein: Int // grams
    public let fat: Int // grams
    public let isApproximate: Bool?
    public let missingFields: [String]?
}

public nonisolated struct ProfileWithGoals: Codable, Equatable, Sendable {
    public let profile: UserProfile
    public let goals: DailyGoals
}

public nonisolated struct UserProfileInput: Codable, Sendable {
    public var name: NullableUpdate<String> = .unchanged
    public var age: NullableUpdate<Int> = .unchanged
    public var gender: NullableUpdate<Gender> = .unchanged
    public var height: NullableUpdate<HeightImperial> = .unchanged
    public var weight: NullableUpdate<Int> = .unchanged
    public var activityLevel: NullableUpdate<ActivityLevel> = .unchanged
    public var calorieDeficit: NullableUpdate<CalorieDeficit> = .unchanged
    public var dietType: NullableUpdate<DietType> = .unchanged
    public var waterLevel: NullableUpdate<Int> = .unchanged

    private enum CodingKeys: String, CodingKey {
        case name, age, gender, weight
        case heightFeet, heightInches
        case activityLevel, calorieDeficit, dietType, waterLevel
    }

    public init(
        name: NullableUpdate<String> = .unchanged,
        age: NullableUpdate<Int> = .unchanged,
        gender: NullableUpdate<Gender> = .unchanged,
        height: NullableUpdate<HeightImperial> = .unchanged,
        weight: NullableUpdate<Int> = .unchanged,
        activityLevel: NullableUpdate<ActivityLevel> = .unchanged,
        calorieDeficit: NullableUpdate<CalorieDeficit> = .unchanged,
        dietType: NullableUpdate<DietType> = .unchanged,
        waterLevel: NullableUpdate<Int> = .unchanged
    ) {
        self.name = name
        self.age = age
        self.gender = gender
        self.height = height
        self.weight = weight
        self.activityLevel = activityLevel
        self.calorieDeficit = calorieDeficit
        self.dietType = dietType
        self.waterLevel = waterLevel
    }

    /// Convenience initializer using values directly. Non-nil values are set to `.set(val)`, while `nil` defaults to `.unchanged`.
    public init(
        name: String? = nil,
        age: Int? = nil,
        gender: Gender? = nil,
        height: HeightImperial? = nil,
        weight: Int? = nil,
        activityLevel: ActivityLevel? = nil,
        calorieDeficit: CalorieDeficit? = nil,
        dietType: DietType? = nil,
        waterLevel: Int? = nil
    ) {
        self.name = name.map { .set($0) } ?? .unchanged
        self.age = age.map { .set($0) } ?? .unchanged
        self.gender = gender.map { .set($0) } ?? .unchanged
        self.height = height.map { .set($0) } ?? .unchanged
        self.weight = weight.map { .set($0) } ?? .unchanged
        self.activityLevel = activityLevel.map { .set($0) } ?? .unchanged
        self.calorieDeficit = calorieDeficit.map { .set($0) } ?? .unchanged
        self.dietType = dietType.map { .set($0) } ?? .unchanged
        self.waterLevel = waterLevel.map { .set($0) } ?? .unchanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.name) {
            name = (try? container.decode(String.self, forKey: .name)).map { .set($0) } ?? .clear
        }
        if container.contains(.age) {
            age = (try? container.decode(Int.self, forKey: .age)).map { .set($0) } ?? .clear
        }
        if container.contains(.gender) {
            gender = (try? container.decode(Gender.self, forKey: .gender)).map { .set($0) } ?? .clear
        }
        if container.contains(.heightFeet) || container.contains(.heightInches) {
            if let feet = try? container.decode(Int.self, forKey: .heightFeet),
               let inches = try? container.decode(Int.self, forKey: .heightInches) {
                height = .set(HeightImperial(feet: feet, inches: inches))
            } else {
                height = .clear
            }
        }
        if container.contains(.weight) {
            weight = (try? container.decode(Int.self, forKey: .weight)).map { .set($0) } ?? .clear
        }
        if container.contains(.activityLevel) {
            activityLevel = (try? container.decode(ActivityLevel.self, forKey: .activityLevel)).map { .set($0) } ?? .clear
        }
        if container.contains(.calorieDeficit) {
            calorieDeficit = (try? container.decode(CalorieDeficit.self, forKey: .calorieDeficit)).map { .set($0) } ?? .clear
        }
        if container.contains(.dietType) {
            dietType = (try? container.decode(DietType.self, forKey: .dietType)).map { .set($0) } ?? .clear
        }
        if container.contains(.waterLevel) {
            waterLevel = (try? container.decode(Int.self, forKey: .waterLevel)).map { .set($0) } ?? .clear
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch name {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .name)
        case .clear: try container.encodeNil(forKey: .name)
        }

        switch age {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .age)
        case .clear: try container.encodeNil(forKey: .age)
        }

        switch gender {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .gender)
        case .clear: try container.encodeNil(forKey: .gender)
        }

        switch height {
        case .unchanged: break
        case .set(let h):
            try container.encode(h.feet, forKey: .heightFeet)
            try container.encode(h.inches, forKey: .heightInches)
        case .clear:
            try container.encodeNil(forKey: .heightFeet)
            try container.encodeNil(forKey: .heightInches)
        }

        switch weight {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .weight)
        case .clear: try container.encodeNil(forKey: .weight)
        }

        switch activityLevel {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .activityLevel)
        case .clear: try container.encodeNil(forKey: .activityLevel)
        }

        switch calorieDeficit {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .calorieDeficit)
        case .clear: try container.encodeNil(forKey: .calorieDeficit)
        }

        switch dietType {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .dietType)
        case .clear: try container.encodeNil(forKey: .dietType)
        }

        switch waterLevel {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .waterLevel)
        case .clear: try container.encodeNil(forKey: .waterLevel)
        }
    }
}

// MARK: - Food Diary Models

public nonisolated enum MealType: String, Codable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snacks
}

public nonisolated enum AddedMethod: String, Codable, Sendable {
    case manual
    case barcode
    case image
    case recipe
}

public nonisolated struct DiaryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let userId: String
    public let date: String // YYYY-MM-DD
    public let mealType: MealType
    public let foodName: String
    public let foodImage: String?
    public let servingSize: Double?
    public let calories: Double?
    public let protein: Double?
    public let carbs: Double?
    public let fat: Double?
    public let fiber: Double?
    public let sodium: Double?
    public let cholesterol: Double?
    public let ingredients: [ScanIngredient]?
    public let addedMethod: AddedMethod?
    public let createdAt: String
    public let updatedAt: String
}

public nonisolated struct DiaryEntryInput: Codable, Sendable {
    public let date: String // YYYY-MM-DD
    public let mealType: MealType
    public let foodName: String
    public var foodImage: String?
    public var servingSize: Double?
    public var calories: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var fiber: Double?
    public var sodium: Double?
    public var cholesterol: Double?
    public var ingredients: [ScanIngredient]?
    public var addedMethod: AddedMethod?

    public init(
        date: String,
        mealType: MealType,
        foodName: String,
        servingSize: Double? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        fiber: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil,
        foodImage: String? = nil,
        ingredients: [ScanIngredient]? = nil,
        addedMethod: AddedMethod? = nil
    ) {
        self.date = date
        self.mealType = mealType
        self.foodName = foodName
        self.servingSize = servingSize
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sodium = sodium
        self.cholesterol = cholesterol
        self.foodImage = foodImage
        self.ingredients = ingredients
        self.addedMethod = addedMethod
    }
}

public nonisolated struct DiaryEntryUpdate: Codable, Sendable {
    public var foodName: NullableUpdate<String> = .unchanged
    public var servingSize: NullableUpdate<Double> = .unchanged
    public var calories: NullableUpdate<Double> = .unchanged
    public var protein: NullableUpdate<Double> = .unchanged
    public var carbs: NullableUpdate<Double> = .unchanged
    public var fat: NullableUpdate<Double> = .unchanged
    public var fiber: NullableUpdate<Double> = .unchanged
    public var sodium: NullableUpdate<Double> = .unchanged
    public var cholesterol: NullableUpdate<Double> = .unchanged
    public var foodImage: NullableUpdate<String> = .unchanged
    public var ingredients: NullableUpdate<[ScanIngredient]> = .unchanged
    public var addedMethod: NullableUpdate<AddedMethod> = .unchanged

    private enum CodingKeys: String, CodingKey {
        case foodName, servingSize, calories, protein, carbs, fat
        case fiber, sodium, cholesterol, foodImage, ingredients, addedMethod
    }

    public init(
        foodName: NullableUpdate<String> = .unchanged,
        servingSize: NullableUpdate<Double> = .unchanged,
        calories: NullableUpdate<Double> = .unchanged,
        protein: NullableUpdate<Double> = .unchanged,
        carbs: NullableUpdate<Double> = .unchanged,
        fat: NullableUpdate<Double> = .unchanged,
        fiber: NullableUpdate<Double> = .unchanged,
        sodium: NullableUpdate<Double> = .unchanged,
        cholesterol: NullableUpdate<Double> = .unchanged,
        foodImage: NullableUpdate<String> = .unchanged,
        ingredients: NullableUpdate<[ScanIngredient]> = .unchanged,
        addedMethod: NullableUpdate<AddedMethod> = .unchanged
    ) {
        self.foodName = foodName
        self.servingSize = servingSize
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sodium = sodium
        self.cholesterol = cholesterol
        self.foodImage = foodImage
        self.ingredients = ingredients
        self.addedMethod = addedMethod
    }

    public init(
        foodName: String? = nil,
        servingSize: Double? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        fiber: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil,
        foodImage: String? = nil,
        ingredients: [ScanIngredient]? = nil,
        addedMethod: AddedMethod? = nil
    ) {
        self.foodName = foodName.map { .set($0) } ?? .unchanged
        self.servingSize = servingSize.map { .set($0) } ?? .unchanged
        self.calories = calories.map { .set($0) } ?? .unchanged
        self.protein = protein.map { .set($0) } ?? .unchanged
        self.carbs = carbs.map { .set($0) } ?? .unchanged
        self.fat = fat.map { .set($0) } ?? .unchanged
        self.fiber = fiber.map { .set($0) } ?? .unchanged
        self.sodium = sodium.map { .set($0) } ?? .unchanged
        self.cholesterol = cholesterol.map { .set($0) } ?? .unchanged
        self.foodImage = foodImage.map { .set($0) } ?? .unchanged
        self.ingredients = ingredients.map { .set($0) } ?? .unchanged
        self.addedMethod = addedMethod.map { .set($0) } ?? .unchanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.foodName) {
            foodName = (try? container.decode(String.self, forKey: .foodName)).map { .set($0) } ?? .clear
        }
        if container.contains(.servingSize) {
            servingSize = (try? container.decode(Double.self, forKey: .servingSize)).map { .set($0) } ?? .clear
        }
        if container.contains(.calories) {
            calories = (try? container.decode(Double.self, forKey: .calories)).map { .set($0) } ?? .clear
        }
        if container.contains(.protein) {
            protein = (try? container.decode(Double.self, forKey: .protein)).map { .set($0) } ?? .clear
        }
        if container.contains(.carbs) {
            carbs = (try? container.decode(Double.self, forKey: .carbs)).map { .set($0) } ?? .clear
        }
        if container.contains(.fat) {
            fat = (try? container.decode(Double.self, forKey: .fat)).map { .set($0) } ?? .clear
        }
        if container.contains(.fiber) {
            fiber = (try? container.decode(Double.self, forKey: .fiber)).map { .set($0) } ?? .clear
        }
        if container.contains(.sodium) {
            sodium = (try? container.decode(Double.self, forKey: .sodium)).map { .set($0) } ?? .clear
        }
        if container.contains(.cholesterol) {
            cholesterol = (try? container.decode(Double.self, forKey: .cholesterol)).map { .set($0) } ?? .clear
        }
        if container.contains(.foodImage) {
            foodImage = (try? container.decode(String.self, forKey: .foodImage)).map { .set($0) } ?? .clear
        }
        if container.contains(.ingredients) {
            ingredients = (try? container.decode([ScanIngredient].self, forKey: .ingredients)).map { .set($0) } ?? .clear
        }
        if container.contains(.addedMethod) {
            addedMethod = (try? container.decode(AddedMethod.self, forKey: .addedMethod)).map { .set($0) } ?? .clear
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch foodName {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .foodName)
        case .clear: try container.encodeNil(forKey: .foodName)
        }

        switch servingSize {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .servingSize)
        case .clear: try container.encodeNil(forKey: .servingSize)
        }

        switch calories {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .calories)
        case .clear: try container.encodeNil(forKey: .calories)
        }

        switch protein {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .protein)
        case .clear: try container.encodeNil(forKey: .protein)
        }

        switch carbs {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .carbs)
        case .clear: try container.encodeNil(forKey: .carbs)
        }

        switch fat {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .fat)
        case .clear: try container.encodeNil(forKey: .fat)
        }

        switch fiber {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .fiber)
        case .clear: try container.encodeNil(forKey: .fiber)
        }

        switch sodium {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .sodium)
        case .clear: try container.encodeNil(forKey: .sodium)
        }

        switch cholesterol {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .cholesterol)
        case .clear: try container.encodeNil(forKey: .cholesterol)
        }

        switch foodImage {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .foodImage)
        case .clear: try container.encodeNil(forKey: .foodImage)
        }

        switch ingredients {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .ingredients)
        case .clear: try container.encodeNil(forKey: .ingredients)
        }

        switch addedMethod {
        case .unchanged: break
        case .set(let v): try container.encode(v, forKey: .addedMethod)
        case .clear: try container.encodeNil(forKey: .addedMethod)
        }
    }
}

public nonisolated struct DailyTotals: Codable, Equatable, Sendable {
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let fiber: Double
    public let sodium: Double
    public let cholesterol: Double
}
