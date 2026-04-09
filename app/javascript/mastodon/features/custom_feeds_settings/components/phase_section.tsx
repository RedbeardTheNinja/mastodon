import { useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';
import type { MessageDescriptor } from 'react-intl';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';
import { Icon } from 'mastodon/components/icon';

import { AlgorithmOptions } from './step_options/algorithm_options';
import { AlgorithmicFilterOptions } from './step_options/algorithmic_filter_options';
import { BlockedTagsOptions } from './step_options/blocked_tags_options';
import { FriendsLikedOptions } from './step_options/friends_liked_options';
import { OnInteractionOptions } from './step_options/on_interaction_options';
import { RemotePublicTimelineOptions } from './step_options/remote_public_timeline_options';
import { RemoteTagTimelineOptions } from './step_options/remote_tag_timeline_options';
import { TimeBasedOptions } from './step_options/time_based_options';

const messages = defineMessages({
  removeStep: {
    id: 'custom_feeds.phase.remove_step',
    defaultMessage: 'Remove',
  },
});

export interface StepDraft {
  key: string;
  step_type: string;
  options: Record<string, unknown>;
}

// Step types that may be added more than once per phase.
const MULTI_INSTANCE_STEP_TYPES = new Set(['remote_tag_timeline']);

export interface StepOption {
  value: string;
  label: MessageDescriptor;
}

interface Props {
  phaseLabel: MessageDescriptor;
  addLabel: MessageDescriptor;
  drafts: StepDraft[];
  availableOptions: StepOption[];
  /** If set, hide the add dropdown once this many steps are present. */
  maxSteps?: number;
  onAdd: (stepType: string) => void;
  onRemove: (key: string) => void;
  onOptionsChange: (key: string, options: Record<string, unknown>) => void;
}

const StepOptionsForm = ({
  stepType,
  options,
  onChange,
}: {
  stepType: string;
  options: Record<string, unknown>;
  onChange: (opts: Record<string, unknown>) => void;
}) => {
  if (stepType === 'remote_tag_timeline') {
    return <RemoteTagTimelineOptions options={options} onChange={onChange} />;
  }
  if (stepType === 'remote_public_timeline') {
    return (
      <RemotePublicTimelineOptions options={options} onChange={onChange} />
    );
  }
  if (stepType === 'friends_liked') {
    return <FriendsLikedOptions options={options} onChange={onChange} />;
  }
  if (stepType === 'blocked_tags') {
    return <BlockedTagsOptions options={options} onChange={onChange} />;
  }
  if (stepType === 'on_interaction') {
    return <OnInteractionOptions options={options} onChange={onChange} />;
  }
  if (stepType === 'time_based') {
    return <TimeBasedOptions options={options} onChange={onChange} />;
  }
  if (stepType === 'affinity_score') {
    return <AlgorithmOptions options={options} onChange={onChange} />;
  }
  if (
    stepType === 'min_score' ||
    stepType === 'top_k_per_batch' ||
    stepType === 'min_signals'
  ) {
    return (
      <AlgorithmicFilterOptions
        stepType={stepType}
        options={options}
        onChange={onChange}
      />
    );
  }
  return null;
};

interface StepRowProps {
  draft: StepDraft;
  label: MessageDescriptor | undefined;
  onRemove: (key: string) => void;
  onOptionsChange: (key: string, options: Record<string, unknown>) => void;
}

const StepRow: React.FC<StepRowProps> = ({
  draft,
  label,
  onRemove,
  onOptionsChange,
}) => {
  const intl = useIntl();

  const handleRemove = useCallback(() => {
    onRemove(draft.key);
  }, [onRemove, draft.key]);

  const handleOptionsChange = useCallback(
    (opts: Record<string, unknown>) => {
      onOptionsChange(draft.key, opts);
    },
    [onOptionsChange, draft.key],
  );

  return (
    <div className='phase-section__step'>
      <div className='phase-section__step-header'>
        <span className='phase-section__step-label'>
          {label ? intl.formatMessage(label) : draft.step_type}
        </span>
        <button
          type='button'
          className='icon-button icon-button--destructive'
          title={intl.formatMessage(messages.removeStep)}
          aria-label={intl.formatMessage(messages.removeStep)}
          onClick={handleRemove}
        >
          <Icon id='delete' icon={DeleteIcon} />
        </button>
      </div>
      <StepOptionsForm
        stepType={draft.step_type}
        options={draft.options}
        onChange={handleOptionsChange}
      />
    </div>
  );
};

export const PhaseSection: React.FC<Props> = ({
  phaseLabel,
  addLabel,
  drafts,
  availableOptions,
  maxSteps,
  onAdd,
  onRemove,
  onOptionsChange,
}) => {
  const intl = useIntl();

  const addedTypes = new Set(drafts.map((d) => d.step_type));
  const atMax = maxSteps !== undefined && drafts.length >= maxSteps;
  const remaining = atMax
    ? []
    : availableOptions.filter(
        (o) =>
          !addedTypes.has(o.value) || MULTI_INSTANCE_STEP_TYPES.has(o.value),
      );

  const handleAddChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const val = e.target.value;
      if (val) onAdd(val);
      e.target.value = '';
    },
    [onAdd],
  );

  const labelFor = useCallback(
    (stepType: string) =>
      availableOptions.find((o) => o.value === stepType)?.label,
    [availableOptions],
  );

  return (
    <div className='phase-section'>
      <div className='phase-section__heading'>
        {intl.formatMessage(phaseLabel)}
      </div>

      {drafts.map((draft) => (
        <StepRow
          key={draft.key}
          draft={draft}
          label={labelFor(draft.step_type)}
          onRemove={onRemove}
          onOptionsChange={onOptionsChange}
        />
      ))}

      {remaining.length > 0 && (
        <div className='phase-section__add'>
          <select
            className='phase-section__add-select'
            defaultValue=''
            onChange={handleAddChange}
          >
            <option value='' disabled>
              {intl.formatMessage(addLabel)}
            </option>
            {remaining.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {intl.formatMessage(opt.label)}
              </option>
            ))}
          </select>
        </div>
      )}

      {drafts.length === 0 && remaining.length === 0 && (
        <div className='phase-section__empty'>
          <FormattedMessage
            id='custom_feeds.phase.no_options'
            defaultMessage='No options available'
          />
        </div>
      )}
    </div>
  );
};
