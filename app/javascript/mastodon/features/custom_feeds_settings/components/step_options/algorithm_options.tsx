import { useCallback } from 'react';

import { defineMessages, useIntl } from 'react-intl';

const messages = defineMessages({
  batchSizeLabel: {
    id: 'custom_feeds.step_options.algorithm_batch_size_label',
    defaultMessage: 'Candidates per run',
  },
  batchSizeHint: {
    id: 'custom_feeds.step_options.algorithm_batch_size_hint',
    defaultMessage: 'How many pending candidates to score and evaluate each time the algorithm runs.',
  },
  maxAgeLabel: {
    id: 'custom_feeds.step_options.algorithm_max_age_label',
    defaultMessage: 'Max pending age (hours)',
  },
  maxAgeHint: {
    id: 'custom_feeds.step_options.algorithm_max_age_hint',
    defaultMessage: 'Candidates older than this are discarded without scoring.',
  },
});

interface Props {
  options: Record<string, unknown>;
  onChange: (opts: Record<string, unknown>) => void;
}

export const AlgorithmOptions: React.FC<Props> = ({ options, onChange }) => {
  const intl = useIntl();

  const batchSize = Number(options.batch_size ?? 100);
  const maxAge    = Number(options.max_pending_age_hours ?? 48);

  const handleBatchSize = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({ ...options, batch_size: parseInt(e.target.value, 10) || 100 });
    },
    [options, onChange],
  );

  const handleMaxAge = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({ ...options, max_pending_age_hours: parseInt(e.target.value, 10) || 48 });
    },
    [options, onChange],
  );

  return (
    <div className='step-options'>
      <label className='step-options__label'>
        {intl.formatMessage(messages.batchSizeLabel)}
        <span className='step-options__hint'>{intl.formatMessage(messages.batchSizeHint)}</span>
        <input
          type='number'
          className='step-options__input'
          value={batchSize}
          min={1}
          max={500}
          onChange={handleBatchSize}
        />
      </label>

      <label className='step-options__label'>
        {intl.formatMessage(messages.maxAgeLabel)}
        <span className='step-options__hint'>{intl.formatMessage(messages.maxAgeHint)}</span>
        <input
          type='number'
          className='step-options__input'
          value={maxAge}
          min={1}
          max={720}
          onChange={handleMaxAge}
        />
      </label>
    </div>
  );
};
