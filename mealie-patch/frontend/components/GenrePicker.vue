<template>
  <v-dialog
    v-model="visible"
    max-width="480"
    persistent
  >
    <v-card>
      <v-card-title class="text-h6 pa-4 pb-2">
        What food do you enjoy?
      </v-card-title>
      <v-card-subtitle class="px-4 pb-3">
        Pick up to 3 categories to personalize your recommendations.
      </v-card-subtitle>

      <v-card-text class="pt-2">
        <div class="genre-grid">
          <v-btn
            v-for="genre in GENRES"
            :key="genre.name"
            :variant="selected.includes(genre.name) ? 'flat' : 'outlined'"
            :color="selected.includes(genre.name) ? 'primary' : 'default'"
            class="genre-btn"
            @click="toggle(genre.name)"
          >
            <span class="mr-2">{{ genre.emoji }}</span>
            {{ genre.name }}
          </v-btn>
        </div>
      </v-card-text>

      <v-card-actions class="px-4 pb-4">
        <v-spacer />
        <v-btn
          color="primary"
          variant="flat"
          :disabled="selected.length === 0 || saving"
          :loading="saving"
          @click="save"
        >
          Save Preferences
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { useUserApi } from "~/composables/api";

const props = defineProps<{
  modelValue: boolean;
  initial?: string[];
}>();

const emit = defineEmits<{
  "update:modelValue": [boolean];
  saved: [string[]];
}>();

const api = useUserApi();

const GENRES = [
  { name: "Italian",    emoji: "🍝" },
  { name: "American",   emoji: "🍔" },
  { name: "Indian",     emoji: "🍛" },
  { name: "Chinese",    emoji: "🥢" },
  { name: "Mexican",    emoji: "🌮" },
  { name: "Vegetarian", emoji: "🥗" },
  { name: "Desserts",   emoji: "🍰" },
];

const visible = computed({
  get: () => props.modelValue,
  set: (v) => emit("update:modelValue", v),
});

const selected = ref<string[]>(props.initial ?? []);
const saving = ref(false);

function toggle(name: string) {
  if (selected.value.includes(name)) {
    selected.value = selected.value.filter((g) => g !== name);
  } else if (selected.value.length < 3) {
    selected.value = [...selected.value, name];
  }
}

async function save() {
  saving.value = true;
  try {
    await api.recommendations.setPreferences({ tags: selected.value });
    emit("saved", selected.value);
    visible.value = false;
  } finally {
    saving.value = false;
  }
}
</script>

<style scoped>
.genre-grid {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
}

.genre-btn {
  height: 48px !important;
  text-transform: none;
  font-size: 0.9rem;
}
</style>
