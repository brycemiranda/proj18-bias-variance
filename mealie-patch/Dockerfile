FROM ghcr.io/mealie-recipes/mealie:v2.2.0

# Backend: recommendation service + routes + schema
COPY mealie-app-patches/services/observability_metrics.py /app/mealie/services/observability_metrics.py
COPY mealie-app-patches/routes/__init__.py /app/mealie/routes/__init__.py
COPY mealie-app-patches/routes/metrics.py /app/mealie/routes/metrics.py
COPY mealie-patch/backend/schema/recommendations.py /app/mealie/schema/recommendations.py
COPY mealie-patch/backend/routes/recommendations.py /app/mealie/routes/recommendations.py
COPY mealie-patch/backend/services/recommendation_service.py /app/mealie/services/recommendation_service.py
COPY mealie-patch/backend/db/models/user_ml_preferences.py /app/mealie/db/models/users/user_ml_preferences.py
COPY mealie-patch/backend/alembic/2026-04-17-05.30.00_c1f7f0d9a9a1_add_user_ml_preferences.py \
     /app/mealie/alembic/versions/2026-04-17-05.30.00_c1f7f0d9a9a1_add_user_ml_preferences.py

# Frontend: recommendation component + page integration + API client
COPY mealie-patch/frontend/components/AppRecommendedForYou.vue \
     /app/frontend/app/components/AppRecommendedForYou.vue
COPY mealie-patch/frontend/components/GenrePicker.vue \
     /app/frontend/app/components/GenrePicker.vue
COPY mealie-patch/frontend/components/RecipeDetailModal.vue \
     /app/frontend/app/components/RecipeDetailModal.vue
COPY mealie-patch/frontend/components/Domain/Recipe/RecipeExplorerPage/RecipeExplorerPage.vue \
     /app/frontend/app/components/Domain/Recipe/RecipeExplorerPage/RecipeExplorerPage.vue
COPY mealie-patch/frontend/api/types/recommendations.ts \
     /app/frontend/app/lib/api/types/recommendations.ts
COPY mealie-patch/frontend/api/user/recommendations.ts \
     /app/frontend/app/lib/api/user/recommendations.ts
