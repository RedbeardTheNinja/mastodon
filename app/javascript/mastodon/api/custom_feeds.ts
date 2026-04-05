import {
  apiRequestGet,
  apiRequestPost,
  apiRequestPut,
  apiRequestDelete,
} from 'mastodon/api';
import type {
  ApiCustomFeedConfigJSON,
  ApiCustomFeedConfigInputJSON,
} from 'mastodon/api_types/custom_feeds';

export const apiGetCustomFeeds = () =>
  apiRequestGet<ApiCustomFeedConfigJSON[]>('v1/custom_feeds');

export const apiGetCustomFeed = (id: string) =>
  apiRequestGet<ApiCustomFeedConfigJSON>(`v1/custom_feeds/${id}`);

export const apiCreateCustomFeed = (config: ApiCustomFeedConfigInputJSON) =>
  apiRequestPost<ApiCustomFeedConfigJSON>('v1/custom_feeds', config);

export const apiUpdateCustomFeed = (
  id: string,
  config: ApiCustomFeedConfigInputJSON,
) => apiRequestPut<ApiCustomFeedConfigJSON>(`v1/custom_feeds/${id}`, config);

export const apiDeleteCustomFeed = (id: string) =>
  apiRequestDelete(`v1/custom_feeds/${id}`);
