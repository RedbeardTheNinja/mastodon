import { useCallback } from 'react';

import { defineMessages, useIntl } from 'react-intl';

const messages = defineMessages({
  minScoreLabel: {
    id: 'custom_feeds.step_options.min_score_label',
    defaultMessage: 'Minimum score',
  },
  minScoreHint: {
    id: 'custom_feeds.step_options.min_score_hint',
    defaultMessage: 'Candidates with a score below this threshold are discarded. Higher values mean stricter selection.',
  },
  topKLabel: {
    id: 'custom_feeds.step_options.top_k_label',
    defaultMessage: 'Max posts per run',
  },
  topKHint: {
    id: 'custom_feeds.step_options.top_k_hint',
    defaultMessage: 'Only promote the top N highest-scoring candidates each time the algorithm runs.',
  },
  minSignalsLabel: {
    id: 'custom_feeds.step_options.min_signals_label',
    defaultMessage: 'Minimum signals required',
  },
  minSignalsHint: {
    id: 'custom_feeds.step_options.min_signals_hint',
    defaultMessage: 'Wait until this many interactions have been recorded before starting to promote posts.',
  },
});

interface Props {
  stepType: string;
  options: Record<string, unknown>;
  onChange: (opts: Record<string, unknown>) => void;
}

export const AlgorithmicFilterOptions: React.FC<Props> = ({ stepType, options, onChange }) => {
  const intl = useIntl();

  const handleNumberChange = useCallback(
    (key: string, fallback: number) => (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({ ...options, [key]: parseFloat(e.target.value) || fallback });
    },
    [options, onChange],
  );

  if (stepType === 'min_score') {
    const threshold = Number(options.threshold ?? 0.1);
    return (
      <div className='step-options'>
        <label className='step-options__label'>
          {intl.formatMessage(messages.minScoreLabel)}
          <span className='step-options__hint'>{intl.formatMessage(messages.minScoreHint)}</span>
          <input
            type='number'
            className='step-options__input'
            value={threshold}
            min={0}
            step={0.1}
            onChange={handleNumberChange('threshold', 0.1)}
          />
        </label>
      </div>
    );
  }

  if (stepType === 'top_k_per_batch') {
    const k = Number(options.k ?? 10);
    return (
      <div className='step-options'>
        <label className='step-options__label'>
          {intl.formatMessage(messages.topKLabel)}
          <span className='step-options__hint'>{intl.formatMessage(messages.topKHint)}</span>
          <input
            type='number'
            className='step-options__input'
            value={k}
            min={1}
            max={100}
            onChange={handleNumberChange('k', 10)}
          />
        </label>
      </div>
    );
  }

  if (stepType === 'min_signals') {
    const count = Number(options.count ?? 5);
    return (
      <div className='step-options'>
        <label className='step-options__label'>
          {intl.formatMessage(messages.minSignalsLabel)}
          <span className='step-options__hint'>{intl.formatMessage(messages.minSignalsHint)}</span>
          <input
            type='number'
            className='step-options__input'
            value={count}
            min={1}
            onChange={handleNumberChange('count', 5)}
          />
        </label>
      </div>
    );
  }

  return null;
};
