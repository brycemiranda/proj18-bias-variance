from pydantic import UUID4, Field

from mealie.schema._mealie import MealieModel


class RecommendationStatus(MealieModel):
    needs_onboarding: bool
    has_vector: bool
    rating_count: int


class RecommendationPreferencesIn(MealieModel):
    tags: list[str]


class RecommendationDismissIn(MealieModel):
    recipe_id: UUID4


class RecommendationAck(MealieModel):
    status: str = "ok"


class RecommendationItem(MealieModel):
    recipe_id: UUID4
    slug: str | None = None
    name: str
    description: str | None = None
    image: str | None = None
    rating: float | None = None
    tags: list[str] = Field(default_factory=list)
    because_tags: list[str] = Field(default_factory=list)
    score: float | None = None
    rank: int | None = None


class RecommendationResult(MealieModel):
    recommendations: list[RecommendationItem]
    cold_start: bool
    model_version: str


class DiscoveryItem(MealieModel):
    recipe_id: str
    name: str
    description: str = ""
    category: str
    tags: list[str] = Field(default_factory=list)
    ingredients: list[str] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)
    score: float = 0.0


class DiscoveryResult(MealieModel):
    items: list[DiscoveryItem]
    page: int
    total: int
    cold_start: bool


class AutoTagIn(MealieModel):
    ingredients: list[str]


class AutoTagResult(MealieModel):
    categories: list[str]
    tags: list[str]
    confidence: float


class DiscoveryRatingIn(MealieModel):
    recipe_id: str
    tags: list[str] = Field(default_factory=list)
    rating: int
