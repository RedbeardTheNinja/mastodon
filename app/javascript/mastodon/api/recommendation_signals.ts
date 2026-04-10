import { apiRequestGet, apiRequestPatch, apiRequestDelete } from 'mastodon/api';

export interface ApiRecommendationSignalJSON {
  id: string;
  signal_type: 'tag' | 'account' | 'domain' | 'text_phrase' | 'alt_text_phrase';
  entity_id: string;
  weight: number;
  observation_count: number;
  last_observed_at: string | null;
}

export const apiGetSignals = () =>
  apiRequestGet<ApiRecommendationSignalJSON[]>('v1/recommendation_signals');

export const apiUpdateSignal = (id: string, weight: number) =>
  apiRequestPatch<ApiRecommendationSignalJSON>(
    `v1/recommendation_signals/${id}`,
    { weight },
  );

export const apiDeleteSignal = (id: string) =>
  apiRequestDelete(`v1/recommendation_signals/${id}`);

export const apiDeleteAllSignals = () =>
  apiRequestDelete('v1/recommendation_signals/destroy_all');
