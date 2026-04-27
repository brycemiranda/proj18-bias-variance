export interface RecommendationStatus {
  needsOnboarding: boolean;
  hasVector: boolean;
  ratingCount: number;
}

export interface RecommendationPreferencesIn {
  tags: string[];
}

export interface RecommendationDismissIn {
  recipeId: string;
}

export interface RecommendationItem {
  recipeId: string;
  slug?: string | null;
  name: string;
  description?: string | null;
  image?: string | null;
  rating?: number | null;
  tags?: string[];
  becauseTags?: string[];
  score?: number | null;
  rank?: number | null;
}

export interface RecommendationResult {
  recommendations: RecommendationItem[];
  coldStart: boolean;
  modelVersion: string;
}

export interface DiscoveryItem {
  recipeId: string;
  name: string;
  description?: string;
  category: string;
  tags?: string[];
  ingredients?: string[];
  steps?: string[];
  score?: number;
}

export interface DiscoveryResult {
  items: DiscoveryItem[];
  page: number;
  total: number;
  coldStart: boolean;
}

export interface AutoTagIn {
  ingredients: string[];
}

export interface AutoTagResult {
  categories: string[];
  tags: string[];
  confidence: number;
}

export interface DiscoveryRatingIn {
  recipeId: string;
  tags: string[];
  rating: number;
}
