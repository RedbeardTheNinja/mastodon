import {
  apiGetCustomFeeds,
  apiCreateCustomFeed,
  apiUpdateCustomFeed,
  apiDeleteCustomFeed,
} from 'mastodon/api/custom_feeds';
import type {
  ApiCustomFeedConfigJSON,
  ApiCustomFeedStepInputJSON,
  CustomFeedType,
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
    feedType = 'standard',
    steps,
  }: {
    listId: string;
    feedType?: CustomFeedType;
    steps: ApiCustomFeedStepInputJSON[];
  }) =>
    apiCreateCustomFeed({
      list_id: listId,
      feed_type: feedType,
      enabled: true,
      steps,
    }),
);

export const updateCustomFeed = createDataLoadingThunk(
  'customFeeds/update',
  ({
    id,
    enabled,
    feed_type,
    pull_cadence_minutes,
    steps,
  }: {
    id: string;
    enabled?: boolean;
    feed_type?: CustomFeedType;
    pull_cadence_minutes?: number;
    steps?: ApiCustomFeedStepInputJSON[];
  }) =>
    apiUpdateCustomFeed(id, {
      ...(enabled !== undefined ? { enabled } : {}),
      ...(feed_type !== undefined ? { feed_type } : {}),
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
