<template>
  <v-dialog
    v-model="visible"
    max-width="640"
    scrollable
  >
    <v-card v-if="recipe">
      <v-card-title class="pa-4 pb-2 d-flex align-center ga-3">
        <div class="flex-grow-1">
          <div class="text-h6 font-weight-medium">
            {{ recipe.name }}
          </div>
          <v-chip
            size="x-small"
            color="primary"
            variant="tonal"
            class="mt-1"
          >
            {{ recipe.category }}
          </v-chip>
        </div>
        <v-btn
          icon
          variant="text"
          size="small"
          @click="visible = false"
        >
          <v-icon>mdi-close</v-icon>
        </v-btn>
      </v-card-title>

      <v-divider />

      <v-card-text class="pt-4">
        <p
          v-if="recipe.description"
          class="text-body-2 text-medium-emphasis mb-4"
        >
          {{ recipe.description }}
        </p>

        <div
          v-if="recipe.tags?.length"
          class="d-flex flex-wrap ga-1 mb-4"
        >
          <v-chip
            v-for="tag in recipe.tags.slice(0, 8)"
            :key="tag"
            size="x-small"
            variant="outlined"
          >
            {{ tag }}
          </v-chip>
        </div>

        <div
          v-if="recipe.ingredients?.length"
          class="mb-5"
        >
          <div class="text-subtitle-2 font-weight-medium mb-2">
            Ingredients
          </div>
          <ul class="detail-list">
            <li
              v-for="(ing, i) in recipe.ingredients"
              :key="i"
              class="text-body-2"
            >
              {{ ing }}
            </li>
          </ul>
        </div>

        <div v-if="recipe.steps?.length">
          <div class="text-subtitle-2 font-weight-medium mb-2">
            Steps
          </div>
          <ol class="detail-list">
            <li
              v-for="(step, i) in recipe.steps"
              :key="i"
              class="text-body-2 mb-2"
            >
              {{ step }}
            </li>
          </ol>
        </div>
      </v-card-text>

      <v-divider />

      <v-card-actions class="pa-4 d-flex flex-column align-start ga-2">
        <div class="text-body-2 text-medium-emphasis">
          Rate this recipe:
        </div>
        <div class="d-flex ga-1">
          <v-btn
            v-for="star in 5"
            :key="star"
            icon
            size="small"
            :color="star <= (hoverStar || userRating) ? 'amber' : 'default'"
            variant="text"
            @mouseenter="hoverStar = star"
            @mouseleave="hoverStar = 0"
            @click="rate(star)"
          >
            <v-icon>
              {{ star <= (hoverStar || userRating) ? 'mdi-star' : 'mdi-star-outline' }}
            </v-icon>
          </v-btn>
        </div>
        <div
          v-if="userRating"
          class="text-caption text-success"
        >
          Rated {{ userRating }} ★ — your feed will update over time
        </div>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import type { DiscoveryItem } from "~/lib/api/types/recommendations";
import { useUserApi } from "~/composables/api";

const props = defineProps<{
  modelValue: boolean;
  recipe: DiscoveryItem | null;
}>();

const emit = defineEmits<{
  "update:modelValue": [boolean];
  rated: [string, number];
}>();

const api = useUserApi();
const userRating = ref(0);
const hoverStar = ref(0);

const visible = computed({
  get: () => props.modelValue,
  set: (v) => emit("update:modelValue", v),
});

watch(() => props.recipe, () => {
  userRating.value = 0;
  hoverStar.value = 0;
});

async function rate(stars: number) {
  if (!props.recipe) return;
  userRating.value = stars;
  await api.recommendations.rateDiscovery({
    recipeId: props.recipe.recipeId,
    tags: props.recipe.tags ?? [],
    rating: stars,
  });
  emit("rated", props.recipe.recipeId, stars);
}
</script>

<style scoped>
.detail-list {
  padding-left: 1.5rem;
}

.detail-list li {
  margin-bottom: 0.25rem;
}
</style>
