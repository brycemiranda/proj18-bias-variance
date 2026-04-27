import { BaseAPI } from "../base/base-clients";
import type {
  AutoTagIn,
  AutoTagResult,
  DiscoveryResult,
  DiscoveryRatingIn,
  RecommendationDismissIn,
  RecommendationPreferencesIn,
  RecommendationResult,
  RecommendationStatus,
} from "../types/recommendations";

const prefix = "/api/recommendations";

const routes = {
  base: prefix,
  status: `${prefix}/status`,
  preferences: `${prefix}/preferences`,
  dismiss: `${prefix}/dismiss`,
  discovery: `${prefix}/discovery`,
  autoTag: `${prefix}/auto-tag`,
  rate: `${prefix}/rate`,
};

export class RecommendationApi extends BaseAPI {
  async getStatus() {
    return await this.requests.get<RecommendationStatus>(routes.status);
  }

  async getRecommendations() {
    return await this.requests.get<RecommendationResult>(routes.base);
  }

  async setPreferences(payload: RecommendationPreferencesIn) {
    return await this.requests.post<{ status: string }, RecommendationPreferencesIn>(routes.preferences, payload);
  }

  async dismiss(payload: RecommendationDismissIn) {
    return await this.requests.post<{ status: string }, RecommendationDismissIn>(routes.dismiss, payload);
  }

  async getDiscovery(params?: { page?: number; pageSize?: number; category?: string }) {
    const qs = new URLSearchParams();
    if (params?.page) qs.set("page", String(params.page));
    if (params?.pageSize) qs.set("page_size", String(params.pageSize));
    if (params?.category) qs.set("category", params.category);
    const url = qs.toString() ? `${routes.discovery}?${qs}` : routes.discovery;
    return await this.requests.get<DiscoveryResult>(url);
  }

  async autoTag(payload: AutoTagIn) {
    return await this.requests.post<AutoTagResult, AutoTagIn>(routes.autoTag, payload);
  }

  async rateDiscovery(payload: DiscoveryRatingIn) {
    return await this.requests.post<{ status: string }, DiscoveryRatingIn>(routes.rate, payload);
  }
}
