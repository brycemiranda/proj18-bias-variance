FROM ghcr.io/mealie-recipes/mealie:v2.2.0

# Backend: recommendation service + routes + schema
COPY backend/schema/recommendations.py /app/mealie/schema/recommendations.py
COPY backend/routes/recommendations.py /app/mealie/routes/recommendations.py
COPY backend/services/recommendation_service.py /app/mealie/services/recommendation_service.py
COPY backend/db/models/user_ml_preferences.py /app/mealie/db/models/users/user_ml_preferences.py
COPY backend/alembic/2026-04-17-05.30.00_c1f7f0d9a9a1_add_user_ml_preferences.py \
     /app/mealie/alembic/versions/2026-04-17-05.30.00_c1f7f0d9a9a1_add_user_ml_preferences.py

# Frontend: recommendation component + page integration + API client
COPY frontend/components/AppRecommendedForYou.vue \
     /app/frontend/app/components/AppRecommendedForYou.vue
COPY frontend/components/GenrePicker.vue \
     /app/frontend/app/components/GenrePicker.vue
COPY frontend/components/RecipeDetailModal.vue \
     /app/frontend/app/components/RecipeDetailModal.vue
COPY frontend/components/Domain/Recipe/RecipeExplorerPage/RecipeExplorerPage.vue \
     /app/frontend/app/components/Domain/Recipe/RecipeExplorerPage/RecipeExplorerPage.vue
COPY frontend/api/types/recommendations.ts \
     /app/frontend/app/lib/api/types/recommendations.ts
COPY frontend/api/user/recommendations.ts \
     /app/frontend/app/lib/api/user/recommendations.ts
