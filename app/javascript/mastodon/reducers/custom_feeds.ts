import type { Reducer } from '@reduxjs/toolkit';
import { Map as ImmutableMap } from 'immutable';

import {
  fetchCustomFeeds,
  createCustomFeed,
  updateCustomFeed,
  deleteCustomFeed,
} from 'mastodon/actions/custom_feeds';
import type { ApiCustomFeedConfigJSON } from 'mastodon/api_types/custom_feeds';

type CustomFeedState = ApiCustomFeedConfigJSON | null;
const initialState = ImmutableMap<string, CustomFeedState>();
type State = typeof initialState;

const normalizeConfig = (state: State, config: ApiCustomFeedConfigJSON) =>
  state.set(config.id, config);

const normalizeConfigs = (state: State, configs: ApiCustomFeedConfigJSON[]) => {
  configs.forEach((config) => {
    state = normalizeConfig(state, config);
  });
  return state;
};

export const customFeedsReducer: Reducer<State> = (
  state = initialState,
  action,
) => {
  if (
    fetchCustomFeeds.fulfilled.match(action) &&
    Array.isArray(action.payload)
  ) {
    return normalizeConfigs(state, action.payload);
  } else if (
    createCustomFeed.fulfilled.match(action) ||
    updateCustomFeed.fulfilled.match(action)
  ) {
    return normalizeConfig(state, action.payload);
  } else if (deleteCustomFeed.fulfilled.match(action)) {
    const id = (action.meta.arg as { id: string }).id;
    return state.delete(id);
  }

  return state;
};
