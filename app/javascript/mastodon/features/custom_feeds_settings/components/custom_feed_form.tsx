import { useState, useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import {
  createCustomFeed,
  updateCustomFeed,
} from 'mastodon/actions/custom_feeds';
import { createList, fetchLists } from 'mastodon/actions/lists_typed';
import type {
  ApiCustomFeedConfigJSON,
  ApiCustomFeedStepInputJSON,
  CustomFeedPhase,
  CustomFeedType,
} from 'mastodon/api_types/custom_feeds';
import {
  SelectField,
  ToggleField,
  TextInputField,
} from 'mastodon/components/form_fields';
import { LoadingIndicator } from 'mastodon/components/loading_indicator';
import { getOrderedLists } from 'mastodon/selectors/lists';
import { useAppDispatch, useAppSelector } from 'mastodon/store';

import { PhaseSection } from './phase_section';
import type { StepDraft, StepOption } from './phase_section';

// ---------------------------------------------------------------------------
// Static message descriptors — required by React Intl babel plugin
// ---------------------------------------------------------------------------

const messages = defineMessages({
  listPlaceholder: {
    id: 'custom_feeds.form.list_placeholder',
    defaultMessage: 'Select a list…',
  },
  newListName: {
    id: 'custom_feeds.form.new_list_name',
    defaultMessage: 'New list name',
  },
  newListNamePlaceholder: {
    id: 'custom_feeds.form.new_list_name_placeholder',
    defaultMessage: 'e.g. My Algorithm Feed',
  },
  createNewList: {
    id: 'custom_feeds.form.create_new_list',
    defaultMessage: 'Create new list instead',
  },
  useExistingList: {
    id: 'custom_feeds.form.use_existing_list',
    defaultMessage: 'Use an existing list instead',
  },
  save: { id: 'custom_feeds.form.save', defaultMessage: 'Save' },
  cancel: { id: 'custom_feeds.form.cancel', defaultMessage: 'Cancel' },
  enabledLabel: {
    id: 'custom_feeds.form.enabled',
    defaultMessage: 'Feed enabled',
  },
  enabledHint: {
    id: 'custom_feeds.form.enabled_hint',
    defaultMessage: 'Disable to pause this feed without deleting it.',
  },
  pullCadenceLabel: {
    id: 'custom_feeds.form.pull_cadence',
    defaultMessage: 'Refresh interval',
  },
  pullCadenceHint: {
    id: 'custom_feeds.form.pull_cadence_hint',
    defaultMessage: 'How often to fetch new posts from remote sources.',
  },
  feedTypeLabel: {
    id: 'custom_feeds.form.feed_type',
    defaultMessage: 'Feed type',
  },
  feedTypeStandard: {
    id: 'custom_feeds.form.feed_type_standard',
    defaultMessage: 'Standard — filter and push posts directly',
  },
  feedTypeAlgorithmic: {
    id: 'custom_feeds.form.feed_type_algorithmic',
    defaultMessage: 'Algorithmic — score and rank posts before promoting',
  },
  // Phase labels
  sourcePhase: {
    id: 'custom_feeds.form.source',
    defaultMessage: 'Post sources',
  },
  filterPhase: { id: 'custom_feeds.form.filter', defaultMessage: 'Filters' },
  preFilterPhase: {
    id: 'custom_feeds.form.pre_filter',
    defaultMessage: 'Pre-filters',
  },
  algorithmPhase: {
    id: 'custom_feeds.form.algorithm',
    defaultMessage: 'Algorithm',
  },
  algorithmicFilterPhase: {
    id: 'custom_feeds.form.algorithmic_filter',
    defaultMessage: 'Algorithmic filters',
  },
  removalPhase: {
    id: 'custom_feeds.form.removal_strategy',
    defaultMessage: 'Removal strategy',
  },
  overflowPhase: {
    id: 'custom_feeds.form.overflow_strategy',
    defaultMessage: 'When feed is full',
  },
  // Add-step labels
  addSource: {
    id: 'custom_feeds.phase.source.add',
    defaultMessage: 'Add source…',
  },
  addFilter: {
    id: 'custom_feeds.phase.filter.add',
    defaultMessage: 'Add filter…',
  },
  addPreFilter: {
    id: 'custom_feeds.phase.pre_filter.add',
    defaultMessage: 'Add pre-filter…',
  },
  addAlgorithm: {
    id: 'custom_feeds.phase.algorithm.add',
    defaultMessage: 'Choose algorithm…',
  },
  addAlgorithmicFilter: {
    id: 'custom_feeds.phase.algorithmic_filter.add',
    defaultMessage: 'Add algorithmic filter…',
  },
  addRemoval: {
    id: 'custom_feeds.phase.removal_strategy.add',
    defaultMessage: 'Add removal rule…',
  },
  addOverflow: {
    id: 'custom_feeds.phase.overflow_strategy.add',
    defaultMessage: 'Set overflow rule…',
  },
});

// All step type labels must be statically defined here for the babel plugin.
const stepLabels = defineMessages({
  followedPosts: {
    id: 'custom_feeds.sources.followed_posts',
    defaultMessage: 'Followed accounts (home feed)',
  },
  remoteTagTimeline: {
    id: 'custom_feeds.sources.remote_tag_timeline',
    defaultMessage: 'Remote server — tag timeline',
  },
  remotePublicTimeline: {
    id: 'custom_feeds.sources.remote_public_timeline',
    defaultMessage: 'Remote server — public timeline',
  },
  none: { id: 'custom_feeds.option.none', defaultMessage: 'None' },
  homeFilters: {
    id: 'custom_feeds.filters.home_filters',
    defaultMessage: 'Hide blocked and muted accounts',
  },
  interactedPosts: {
    id: 'custom_feeds.filters.interacted_posts',
    defaultMessage: 'Hide already-interacted posts',
  },
  friendsLiked: {
    id: 'custom_feeds.filters.friends_liked',
    defaultMessage: 'Only posts liked by people you follow',
  },
  blockedTags: {
    id: 'custom_feeds.filters.blocked_tags',
    defaultMessage: 'Block by tag',
  },
  onInteraction: {
    id: 'custom_feeds.removal_strategies.on_interaction',
    defaultMessage: 'Remove on interaction (favourite, boost, or reply)',
  },
  timeBased: {
    id: 'custom_feeds.removal_strategies.time_based',
    defaultMessage: 'Remove after a set time',
  },
  oldestFirst: {
    id: 'custom_feeds.overflow.oldest_first',
    defaultMessage: 'Remove oldest posts first',
  },
  noOverflow: {
    id: 'custom_feeds.overflow.no_overflow',
    defaultMessage: 'Stop adding new posts when full',
  },
  affinityScore: {
    id: 'custom_feeds.algorithms.affinity_score',
    defaultMessage: 'Affinity score — weighted interactions with time decay',
  },
  minScore: {
    id: 'custom_feeds.algorithmic_filters.min_score',
    defaultMessage: 'Minimum score threshold',
  },
  topKPerBatch: {
    id: 'custom_feeds.algorithmic_filters.top_k_per_batch',
    defaultMessage: 'Limit posts per run',
  },
  minSignals: {
    id: 'custom_feeds.algorithmic_filters.min_signals',
    defaultMessage: 'Require minimum signals before starting',
  },
});

// Cadence option labels
const cadenceLabels = defineMessages({
  cadence5: { id: 'custom_feeds.cadence.5', defaultMessage: 'Every 5 minutes' },
  cadence15: {
    id: 'custom_feeds.cadence.15',
    defaultMessage: 'Every 15 minutes',
  },
  cadence30: {
    id: 'custom_feeds.cadence.30',
    defaultMessage: 'Every 30 minutes',
  },
  cadence60: { id: 'custom_feeds.cadence.60', defaultMessage: 'Every hour' },
  cadence120: {
    id: 'custom_feeds.cadence.120',
    defaultMessage: 'Every 2 hours',
  },
  cadence360: {
    id: 'custom_feeds.cadence.360',
    defaultMessage: 'Every 6 hours',
  },
});

const CADENCE_OPTIONS = [
  { value: '5', label: cadenceLabels.cadence5 },
  { value: '15', label: cadenceLabels.cadence15 },
  { value: '30', label: cadenceLabels.cadence30 },
  { value: '60', label: cadenceLabels.cadence60 },
  { value: '120', label: cadenceLabels.cadence120 },
  { value: '360', label: cadenceLabels.cadence360 },
];

// Available step types per phase, ordered by display preference.
const PHASE_OPTIONS: Record<CustomFeedPhase, StepOption[]> = {
  source: [
    { value: 'followed_posts', label: stepLabels.followedPosts },
    { value: 'remote_tag_timeline', label: stepLabels.remoteTagTimeline },
    { value: 'remote_public_timeline', label: stepLabels.remotePublicTimeline },
  ],
  filter: [
    { value: 'home_filters', label: stepLabels.homeFilters },
    { value: 'interacted_posts', label: stepLabels.interactedPosts },
    { value: 'friends_liked', label: stepLabels.friendsLiked },
    { value: 'blocked_tags', label: stepLabels.blockedTags },
  ],
  algorithm: [{ value: 'affinity_score', label: stepLabels.affinityScore }],
  algorithmic_filter: [
    { value: 'min_score', label: stepLabels.minScore },
    { value: 'top_k_per_batch', label: stepLabels.topKPerBatch },
    { value: 'min_signals', label: stepLabels.minSignals },
  ],
  removal_strategy: [
    { value: 'on_interaction', label: stepLabels.onInteraction },
    { value: 'time_based', label: stepLabels.timeBased },
  ],
  overflow_strategy: [
    { value: 'oldest_first', label: stepLabels.oldestFirst },
    { value: 'no_overflow', label: stepLabels.noOverflow },
  ],
};

// Default options for step types that need pre-populated options.
const DEFAULT_OPTIONS: Record<string, Record<string, unknown>> = {
  remote_tag_timeline: {
    sources: [{ domain: '', tag: '' }],
    limit_per_run: 40,
  },
  remote_public_timeline: {
    sources: [{ domain: '', local_only: true }],
    limit_per_run: 40,
  },
  friends_liked: { min_interactions: 1 },
  blocked_tags: { tags: [''] },
  on_interaction: { delay_seconds: 5 },
  time_based: { duration_minutes: 60 },
  affinity_score: { batch_size: 100, max_pending_age_hours: 48 },
  min_score: { threshold: 0.1 },
  top_k_per_batch: { k: 10 },
  min_signals: { count: 5 },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function stepsFor(
  config: ApiCustomFeedConfigJSON | undefined,
  phase: CustomFeedPhase,
): StepDraft[] {
  return (config?.steps ?? [])
    .filter((s) => s.phase === phase)
    .sort((a, b) => a.position - b.position)
    .map((s) => ({ step_type: s.step_type, options: s.options }));
}

// ---------------------------------------------------------------------------
// Pull-source detection helpers
// ---------------------------------------------------------------------------

const PULL_SOURCE_TYPES = new Set([
  'remote_tag_timeline',
  'remote_public_timeline',
]);

function hasPullSources(drafts: StepDraft[]): boolean {
  return drafts.some((d) => PULL_SOURCE_TYPES.has(d.step_type));
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

interface Props {
  config?: ApiCustomFeedConfigJSON;
  onClose: () => void;
}

export const CustomFeedForm: React.FC<Props> = ({ config, onClose }) => {
  const dispatch = useAppDispatch();
  const intl = useIntl();
  const lists = useAppSelector((state) => getOrderedLists(state));

  const [listId, setListId] = useState(config?.list_id ?? '');
  const [newListName, setNewListName] = useState('');
  const [creatingList, setCreatingList] = useState(false);
  const [feedType, setFeedType] = useState<CustomFeedType>(
    config?.feed_type ?? 'standard',
  );
  const [enabled, setEnabled] = useState(config?.enabled ?? true);
  const [cadence, setCadence] = useState(
    String(config?.pull_cadence_minutes ?? 15),
  );
  const [submitting, setSubmitting] = useState(false);

  const [sourceDrafts, setSourceDrafts] = useState<StepDraft[]>(() =>
    stepsFor(config, 'source'),
  );
  const [filterDrafts, setFilterDrafts] = useState<StepDraft[]>(() =>
    config
      ? stepsFor(config, 'filter')
      : [{ step_type: 'home_filters', options: {} }],
  );
  const [algorithmDrafts, setAlgorithmDrafts] = useState<StepDraft[]>(() =>
    stepsFor(config, 'algorithm'),
  );
  const [algorithmicFilterDrafts, setAlgorithmicFilterDrafts] = useState<
    StepDraft[]
  >(() => stepsFor(config, 'algorithmic_filter'));
  const [removalDrafts, setRemovalDrafts] = useState<StepDraft[]>(() =>
    stepsFor(config, 'removal_strategy'),
  );
  const [overflowDrafts, setOverflowDrafts] = useState<StepDraft[]>(() =>
    stepsFor(config, 'overflow_strategy'),
  );

  // -- Per-phase callbacks ---------------------------------------------------

  const makeAdd = useCallback(
    (setter: React.Dispatch<React.SetStateAction<StepDraft[]>>) =>
      (stepType: string) => {
        setter((prev) => [
          ...prev,
          { step_type: stepType, options: DEFAULT_OPTIONS[stepType] ?? {} },
        ]);
      },
    [],
  );

  const makeRemove = useCallback(
    (setter: React.Dispatch<React.SetStateAction<StepDraft[]>>) =>
      (stepType: string) => {
        setter((prev) => prev.filter((d) => d.step_type !== stepType));
      },
    [],
  );

  const makeOptionsChange = useCallback(
    (setter: React.Dispatch<React.SetStateAction<StepDraft[]>>) =>
      (stepType: string, options: Record<string, unknown>) => {
        setter((prev) =>
          prev.map((d) => (d.step_type === stepType ? { ...d, options } : d)),
        );
      },
    [],
  );

  const addSource = useCallback(makeAdd(setSourceDrafts), [makeAdd]);
  const addFilter = useCallback(makeAdd(setFilterDrafts), [makeAdd]);
  const addAlgorithm = useCallback(makeAdd(setAlgorithmDrafts), [makeAdd]);
  const addAlgorithmicFilter = useCallback(
    makeAdd(setAlgorithmicFilterDrafts),
    [makeAdd],
  );
  const addRemoval = useCallback(makeAdd(setRemovalDrafts), [makeAdd]);
  const addOverflow = useCallback(makeAdd(setOverflowDrafts), [makeAdd]);

  const removeSource = useCallback(makeRemove(setSourceDrafts), [makeRemove]);
  const removeFilter = useCallback(makeRemove(setFilterDrafts), [makeRemove]);
  const removeAlgorithm = useCallback(makeRemove(setAlgorithmDrafts), [
    makeRemove,
  ]);
  const removeAlgorithmicFilter = useCallback(
    makeRemove(setAlgorithmicFilterDrafts),
    [makeRemove],
  );
  const removeRemoval = useCallback(makeRemove(setRemovalDrafts), [makeRemove]);
  const removeOverflow = useCallback(makeRemove(setOverflowDrafts), [
    makeRemove,
  ]);

  const changeSourceOptions = useCallback(makeOptionsChange(setSourceDrafts), [
    makeOptionsChange,
  ]);
  const changeFilterOptions = useCallback(makeOptionsChange(setFilterDrafts), [
    makeOptionsChange,
  ]);
  const changeAlgorithmOptions = useCallback(
    makeOptionsChange(setAlgorithmDrafts),
    [makeOptionsChange],
  );
  const changeAlgorithmicFilterOptions = useCallback(
    makeOptionsChange(setAlgorithmicFilterDrafts),
    [makeOptionsChange],
  );
  const changeRemovalOptions = useCallback(
    makeOptionsChange(setRemovalDrafts),
    [makeOptionsChange],
  );
  const changeOverflowOptions = useCallback(
    makeOptionsChange(setOverflowDrafts),
    [makeOptionsChange],
  );

  // -- Build steps payload ---------------------------------------------------

  const buildSteps = useCallback((): ApiCustomFeedStepInputJSON[] => {
    const allDrafts: { phase: CustomFeedPhase; drafts: StepDraft[] }[] = [
      { phase: 'source', drafts: sourceDrafts },
      { phase: 'filter', drafts: filterDrafts },
      { phase: 'algorithm', drafts: algorithmDrafts },
      { phase: 'algorithmic_filter', drafts: algorithmicFilterDrafts },
      { phase: 'removal_strategy', drafts: removalDrafts },
      { phase: 'overflow_strategy', drafts: overflowDrafts },
    ];

    return allDrafts.flatMap(({ phase, drafts }) =>
      drafts.map((d, position) => ({
        phase,
        step_type: d.step_type,
        position,
        options: d.options,
      })),
    );
  }, [
    sourceDrafts,
    filterDrafts,
    algorithmDrafts,
    algorithmicFilterDrafts,
    removalDrafts,
    overflowDrafts,
  ]);

  // -- Submit ----------------------------------------------------------------

  const handleSubmit = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault();
      setSubmitting(true);

      const doSubmit = async () => {
        try {
          if (config) {
            await dispatch(
              updateCustomFeed({
                id: config.id,
                feed_type: feedType,
                enabled,
                pull_cadence_minutes: parseInt(cadence, 10),
                steps: buildSteps(),
              }),
            );
          } else {
            let resolvedListId = listId;

            if (creatingList) {
              // Create the list first, then use its ID for the feed
              const result = await dispatch(
                createList({ title: newListName.trim() }),
              );
              // createList thunk returns the new list object; extract its id
              const newList = (
                result as unknown as { payload?: { id?: string } }
              ).payload;
              if (!newList?.id) throw new Error('Failed to create list');
              resolvedListId = newList.id;
              void dispatch(fetchLists());
            }

            await dispatch(
              createCustomFeed({
                listId: resolvedListId,
                feedType,
                steps: buildSteps(),
              }),
            );
            if (!creatingList) void dispatch(fetchLists());
          }
          onClose();
        } finally {
          setSubmitting(false);
        }
      };

      void doSubmit();
    },
    [
      dispatch,
      config,
      listId,
      newListName,
      creatingList,
      feedType,
      enabled,
      cadence,
      buildSteps,
      onClose,
    ],
  );

  const handleToggleCreatingList = useCallback(() => {
    setCreatingList((prev) => !prev);
    setListId('');
    setNewListName('');
  }, []);

  // -- Available lists -------------------------------------------------------

  const configuredListIds = useAppSelector((state) =>
    [
      ...(
        state as unknown as {
          customFeeds: {
            valueSeq: () => Iterable<ApiCustomFeedConfigJSON | null>;
          };
        }
      ).customFeeds.valueSeq(),
    ]
      .filter((c): c is ApiCustomFeedConfigJSON => c !== null)
      .map((c) => c.list_id),
  );

  const availableLists = lists.filter(
    (list) =>
      !configuredListIds.includes(list.id) || list.id === config?.list_id,
  );

  const showCadence = hasPullSources(sourceDrafts);
  const isAlgorithmic = feedType === 'algorithmic';

  const handleNewListNameChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setNewListName(e.target.value);
    },
    [],
  );

  const handleListIdChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      setListId(e.target.value);
    },
    [],
  );

  const handleFeedTypeChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      setFeedType(e.target.value as CustomFeedType);
    },
    [],
  );

  const handleCadenceChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      setCadence(e.target.value);
    },
    [],
  );

  const handleEnabledChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setEnabled(e.target.checked);
    },
    [],
  );

  return (
    <form onSubmit={handleSubmit} className='simple_form app-form'>
      {!config && (
        <div className='fields-group'>
          {creatingList ? (
            <TextInputField
              id='cf-new-list-name'
              label={intl.formatMessage(messages.newListName)}
              placeholder={intl.formatMessage(messages.newListNamePlaceholder)}
              value={newListName}
              onChange={handleNewListNameChange}
              required
            />
          ) : (
            <SelectField
              id='cf-list-id'
              label={
                <FormattedMessage
                  id='custom_feeds.form.list'
                  defaultMessage='List to use as source'
                />
              }
              value={listId}
              onChange={handleListIdChange}
              required
            >
              <option value=''>
                {intl.formatMessage(messages.listPlaceholder)}
              </option>
              {availableLists.map((list) => (
                <option key={list.id} value={list.id}>
                  {list.title}
                </option>
              ))}
            </SelectField>
          )}

          <button
            type='button'
            className='custom-feed-form__toggle-list-mode'
            onClick={handleToggleCreatingList}
          >
            {creatingList
              ? intl.formatMessage(messages.useExistingList)
              : intl.formatMessage(messages.createNewList)}
          </button>
        </div>
      )}

      <div className='fields-group'>
        <SelectField
          id='cf-feed-type'
          label={intl.formatMessage(messages.feedTypeLabel)}
          value={feedType}
          onChange={handleFeedTypeChange}
        >
          <option value='standard'>
            {intl.formatMessage(messages.feedTypeStandard)}
          </option>
          <option value='algorithmic'>
            {intl.formatMessage(messages.feedTypeAlgorithmic)}
          </option>
        </SelectField>
      </div>

      {isAlgorithmic && (
        <PhaseSection
          phaseLabel={messages.algorithmPhase}
          addLabel={messages.addAlgorithm}
          drafts={algorithmDrafts}
          availableOptions={PHASE_OPTIONS.algorithm}
          maxSteps={1}
          onAdd={addAlgorithm}
          onRemove={removeAlgorithm}
          onOptionsChange={changeAlgorithmOptions}
        />
      )}

      <PhaseSection
        phaseLabel={messages.sourcePhase}
        addLabel={messages.addSource}
        drafts={sourceDrafts}
        availableOptions={PHASE_OPTIONS.source}
        onAdd={addSource}
        onRemove={removeSource}
        onOptionsChange={changeSourceOptions}
      />

      <PhaseSection
        phaseLabel={
          isAlgorithmic ? messages.preFilterPhase : messages.filterPhase
        }
        addLabel={isAlgorithmic ? messages.addPreFilter : messages.addFilter}
        drafts={filterDrafts}
        availableOptions={PHASE_OPTIONS.filter}
        onAdd={addFilter}
        onRemove={removeFilter}
        onOptionsChange={changeFilterOptions}
      />

      {isAlgorithmic && (
        <PhaseSection
          phaseLabel={messages.algorithmicFilterPhase}
          addLabel={messages.addAlgorithmicFilter}
          drafts={algorithmicFilterDrafts}
          availableOptions={PHASE_OPTIONS.algorithmic_filter}
          onAdd={addAlgorithmicFilter}
          onRemove={removeAlgorithmicFilter}
          onOptionsChange={changeAlgorithmicFilterOptions}
        />
      )}

      <PhaseSection
        phaseLabel={messages.removalPhase}
        addLabel={messages.addRemoval}
        drafts={removalDrafts}
        availableOptions={PHASE_OPTIONS.removal_strategy}
        onAdd={addRemoval}
        onRemove={removeRemoval}
        onOptionsChange={changeRemovalOptions}
      />

      <PhaseSection
        phaseLabel={messages.overflowPhase}
        addLabel={messages.addOverflow}
        drafts={overflowDrafts}
        availableOptions={PHASE_OPTIONS.overflow_strategy}
        onAdd={addOverflow}
        onRemove={removeOverflow}
        onOptionsChange={changeOverflowOptions}
      />

      {showCadence && (
        <div className='fields-group'>
          <SelectField
            id='cf-cadence'
            label={intl.formatMessage(messages.pullCadenceLabel)}
            hint={intl.formatMessage(messages.pullCadenceHint)}
            value={cadence}
            onChange={handleCadenceChange}
          >
            {CADENCE_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {intl.formatMessage(opt.label)}
              </option>
            ))}
          </SelectField>
        </div>
      )}

      {config && (
        <div className='fields-group'>
          <ToggleField
            id='cf-enabled'
            label={intl.formatMessage(messages.enabledLabel)}
            hint={intl.formatMessage(messages.enabledHint)}
            checked={enabled}
            onChange={handleEnabledChange}
          />
        </div>
      )}

      <div className='actions'>
        <button
          type='submit'
          className='button'
          disabled={
            submitting ||
            (!config && (creatingList ? !newListName.trim() : !listId))
          }
        >
          {submitting ? (
            <LoadingIndicator />
          ) : (
            intl.formatMessage(messages.save)
          )}
        </button>

        <button
          type='button'
          className='button button-secondary'
          onClick={onClose}
          disabled={submitting}
        >
          {intl.formatMessage(messages.cancel)}
        </button>
      </div>
    </form>
  );
};
