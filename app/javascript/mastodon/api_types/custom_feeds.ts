// See app/serializers/rest/custom_feed_config_serializer.rb

export type CustomFeedPhase =
  | 'source'
  | 'filter'
  | 'removal_strategy'
  | 'overflow_strategy';

export interface ApiCustomFeedStepJSON {
  id: string;
  phase: CustomFeedPhase;
  step_type: string;
  position: number;
  options: Record<string, unknown>;
}

// Input type used when creating or updating steps (no server-assigned id yet)
export type ApiCustomFeedStepInputJSON = Omit<ApiCustomFeedStepJSON, 'id'>;

export interface ApiCustomFeedConfigJSON {
  id: string;
  list_id: string;
  enabled: boolean;
  pull_cadence_minutes: number;
  steps: ApiCustomFeedStepJSON[];
}

// Input type for create/update payloads
export interface ApiCustomFeedConfigInputJSON {
  list_id?: string;
  enabled?: boolean;
  pull_cadence_minutes?: number;
  steps?: ApiCustomFeedStepInputJSON[];
}
