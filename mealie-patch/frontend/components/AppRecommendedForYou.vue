<template>
  <section class="recommendations-section">
    <div class="d-flex flex-column flex-md-row align-md-center justify-space-between ga-3 mb-3">
      <div>
        <div class="text-h6 font-weight-medium">
          Recommended for You
        </div>
        <div class="text-body-2 text-medium-emphasis">
          Personalized picks from thousands of Food.com recipes.
        </div>
      </div>
      <v-btn
        variant="tonal"
        size="small"
        prepend-icon="mdi-tune"
        @click="showGenrePicker = true"
      >
        Change Preferences
      </v-btn>
    </div>

    <v-tabs
      v-model="activeTab"
      density="compact"
      class="mb-4"
    >
      <v-tab value="foryou">
        For You
      </v-tab>
      <v-tab value="favorites">
        Favorites
      </v-tab>
    </v-tabs>

    <!-- For You tab -->
    <template v-if="activeTab === 'foryou'">
      <div
        v-if="loading"
        class="d-flex justify-center pa-8"
      >
        <v-progress-circular
          indeterminate
          color="primary"
        />
      </div>

      <template v-else-if="discoveryItems.length">
        <div class="discovery-grid">
          <v-card
            v-for="item in discoveryItems"
            :key="item.recipeId"
            class="discovery-card"
            variant="outlined"
            @click="openDetail(item)"
          >
            <div class="discovery-placeholder">
              <v-icon
                size="36"
                color="medium-emphasis"
              >
                mdi-silverware-fork-knife
              </v-icon>
            </div>
            <v-card-text class="pb-2">
              <div class="text-subtitle-2 font-weight-medium discovery-title">
                {{ item.name }}
              </div>
              <v-chip
                size="x-small"
                color="primary"
                variant="tonal"
                class="mt-1 mb-2"
              >
                {{ item.category }}
              </v-chip>
              <div class="d-flex flex-wrap ga-1">
                <v-chip
                  v-for="tag in (item.tags ?? []).slice(0, 3)"
                  :key="tag"
                  size="x-small"
                  variant="outlined"
                >
                  {{ tag }}
                </v-chip>
              </div>
            </v-card-text>
          </v-card>
        </div>

        <div
          v-if="hasMore"
          class="d-flex justify-center mt-4"
        >
          <v-btn
            variant="tonal"
            :loading="loadingMore"
            @click="loadMore"
          >
            Load more
          </v-btn>
        </div>
      </template>

      <v-card
        v-else
        variant="outlined"
        class="recommendation-empty"
      >
        <v-card-text class="pa-6">
          <div class="text-h6 font-weight-medium mb-2">
            No recipes yet
          </div>
          <p class="text-body-2 text-medium-emphasis mb-3">
            Select some food preferences to start your discovery feed.
          </p>
          <v-btn
            color="primary"
            variant="flat"
            @click="showGenrePicker = true"
          >
            Set Preferences
          </v-btn>
        </v-card-text>
      </v-card>
    </template>

    <!-- Favorites tab -->
    <template v-else>
      <template v-if="favorites.length">
        <div class="discovery-grid">
          <v-card
            v-for="item in favorites"
            :key="item.recipeId"
            class="discovery-card"
            variant="outlined"
            @click="openDetail(item)"
          >
            <div class="discovery-placeholder">
              <v-icon
                size="36"
                color="amber"
              >
                mdi-star
              </v-icon>
            </div>
            <v-card-text class="pb-2">
              <div class="text-subtitle-2 font-weight-medium discovery-title">
                {{ item.name }}
              </div>
              <v-chip
                size="x-small"
                color="primary"
                variant="tonal"
                class="mt-1"
              >
                {{ item.category }}
              </v-chip>
            </v-card-text>
          </v-card>
        </div>
      </template>
      <v-card
        v-else
        variant="outlined"
        class="recommendation-empty"
      >
        <v-card-text class="pa-6">
          <div class="text-body-2 text-medium-emphasis">
            Recipes you rate 4+ stars will appear here.
          </div>
        </v-card-text>
      </v-card>
    </template>

    <GenrePicker
      v-model="showGenrePicker"
      :initial="currentCategories"
      @saved="onPreferencesSaved"
    />

    <RecipeDetailModal
      v-model="showDetail"
      :recipe="selectedRecipe"
      @rated="onRated"
    />
  </section>
</template>

<script setup lang="ts">
import type { DiscoveryItem } from "~/lib/api/types/recommendations";
import { useUserApi } from "~/composables/api";
import GenrePicker from "./GenrePicker.vue";
import RecipeDetailModal from "./RecipeDetailModal.vue";

const auth = useMealieAuth();
const api = useUserApi();

const FAV_KEY = "ml_favorites";
const PAGE_SIZE = 20;

const activeTab = ref("foryou");
const loading = ref(true);
const loadingMore = ref(false);
const discoveryItems = ref<DiscoveryItem[]>([]);
const page = ref(1);
const totalItems = ref(0);
const showGenrePicker = ref(false);
const showDetail = ref(false);
const selectedRecipe = ref<DiscoveryItem | null>(null);
const currentCategories = ref<string[]>([]);
const favorites = ref<DiscoveryItem[]>(
  JSON.parse(typeof localStorage !== "undefined" ? (localStorage.getItem(FAV_KEY) ?? "[]") : "[]")
);

const hasMore = computed(() => discoveryItems.value.length < totalItems.value);

async function loadDiscovery(reset = false) {
  if (reset) {
    page.value = 1;
    discoveryItems.value = [];
  }
  try {
    const res = await api.recommendations.getDiscovery({ page: page.value, pageSize: PAGE_SIZE });
    if (!res.data) return;
    if (res.data.coldStart && page.value === 1) {
      showGenrePicker.value = true;
    }
    discoveryItems.value = reset ? res.data.items : [...discoveryItems.value, ...res.data.items];
    totalItems.value = res.data.total;
  } finally {
    loading.value = false;
  }
}

async function loadMore() {
  loadingMore.value = true;
  page.value++;
  try {
    await loadDiscovery();
  } finally {
    loadingMore.value = false;
  }
}

function openDetail(item: DiscoveryItem) {
  selectedRecipe.value = item;
  showDetail.value = true;
}

function onPreferencesSaved(categories: string[]) {
  currentCategories.value = categories;
  loading.value = true;
  loadDiscovery(true);
}

function onRated(recipeId: string, stars: number) {
  if (stars >= 4) {
    const item = discoveryItems.value.find((i) => i.recipeId === recipeId);
    if (item && !favorites.value.find((f) => f.recipeId === recipeId)) {
      favorites.value = [...favorites.value, item];
      if (typeof localStorage !== "undefined") {
        localStorage.setItem(FAV_KEY, JSON.stringify(favorites.value));
      }
    }
  }
}

onMounted(async () => {
  if (!auth.user.value) {
    loading.value = false;
    return;
  }
  const status = await api.recommendations.getStatus();
  if (status.data?.needsOnboarding) {
    showGenrePicker.value = true;
    loading.value = false;
    return;
  }
  await loadDiscovery(true);
});
</script>

<style scoped>
.recommendations-section {
  margin-top: 0.75rem;
}

.recommendation-empty {
  border-style: dashed;
}

.discovery-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
}

.discovery-card {
  cursor: pointer;
  transition: box-shadow 0.15s ease;
}

.discovery-card:hover {
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12);
}

.discovery-placeholder {
  align-items: center;
  background: linear-gradient(135deg, rgba(32, 52, 84, 0.08), rgba(54, 122, 98, 0.12));
  display: flex;
  height: 120px;
  justify-content: center;
}

.discovery-title {
  display: -webkit-box;
  line-height: 1.35;
  overflow: hidden;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
}
</style>
