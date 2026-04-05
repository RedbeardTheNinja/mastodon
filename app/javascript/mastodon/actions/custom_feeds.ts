import {
  apiGetCustomFeeds,
  apiCreateCustomFeed,
  apiUpdateCustomFeed,
  apiDeleteCustomFeed,
} from 'mastodon/api/custom_feeds';
import type {
  ApiCustomFeedConfigJSON,
  ApiCustomFeedStepInputJSON,
} from 'mastodon/api_types/custom_feeds';
import { createDataLoadingThunk } from 'mastodon/store/typed_functions';

export const fetchCustomFeeds = createDataLoadingThunk(
  'customFeeds/fetchAll',
  () => apiGetCustomFeeds(),
);

export const createCustomFeed = createDataLoadingThunk(
  'customFeeds/create',
  ({
    listId,
    steps,
  }: {
    listId: string;
    steps: ApiCustomFeedStepInputJSON[];
  }) =>
    apiCreateCustomFeed({
      list_id: listId,
      enabled: true,
      steps,
    }),
);

export const updateCustomFeed = createDataLoadingThunk(
  'customFeeds/update',
  ({
    id,
    enabled,
    pull_cadence_minutes,
    steps,
  }: {
    id: string;
    enabled?: boolean;
    pull_cadence_minutes?: number;
    steps?: ApiCustomFeedStepInputJSON[];
  }) =>
    apiUpdateCustomFeed(id, {
      ...(enabled !== undefined ? { enabled } : {}),
      ...(pull_cadence_minutes !== undefined ? { pull_cadence_minutes } : {}),
      ...(steps !== undefined ? { steps } : {}),
    }),
);

export const deleteCustomFeed = createDataLoadingThunk(
  'customFeeds/delete',
  ({ id }: { id: string }) => apiDeleteCustomFeed(id),
  (_data, { discardLoadData }) => discardLoadData,
);

export type { ApiCustomFeedConfigJSON };
