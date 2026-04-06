import { useCallback } from 'react';

import { FormattedMessage } from 'react-intl';

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const OnInteractionOptions: React.FC<Props> = ({
  options,
  onChange,
}) => {
  const delaySeconds = (options.delay_seconds as number | undefined) ?? 5;

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const raw = parseInt(e.target.value, 10);
      if (isNaN(raw) || raw < 0) return;
      onChange({ ...options, delay_seconds: raw });
    },
    [options, onChange],
  );

  return (
    <div className='step-options'>
      <div className='step-options__label'>
        <FormattedMessage
          id='custom_feeds.step_options.on_interaction_delay_label'
          defaultMessage='Delay before removing (seconds)'
        />
      </div>
      <div className='step-options__row'>
        <input
          type='number'
          className='step-options__input step-options__input--short'
          min={0}
          value={delaySeconds}
          onChange={handleChange}
        />
      </div>
    </div>
  );
};
