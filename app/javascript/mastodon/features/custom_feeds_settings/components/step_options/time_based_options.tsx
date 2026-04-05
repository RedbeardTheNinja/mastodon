import { useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

const messages = defineMessages({
  unitMinutes: {
    id: 'custom_feeds.step_options.time_based_unit_minutes',
    defaultMessage: 'minutes',
  },
  unitHours: {
    id: 'custom_feeds.step_options.time_based_unit_hours',
    defaultMessage: 'hours',
  },
});

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const TimeBasedOptions: React.FC<Props> = ({ options, onChange }) => {
  const intl = useIntl();
  const durationMinutes = (options.duration_minutes as number | undefined) ?? 60;

  // Represent internally as minutes; display in minutes if < 60 else hours.
  const isHours = durationMinutes >= 60 && durationMinutes % 60 === 0;
  const displayValue = isHours ? durationMinutes / 60 : durationMinutes;
  const displayUnit = isHours ? 'hours' : 'minutes';

  const handleValueChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const raw = parseInt(e.target.value, 10);
      if (isNaN(raw) || raw <= 0) return;
      const minutes = displayUnit === 'hours' ? raw * 60 : raw;
      onChange({ ...options, duration_minutes: minutes });
    },
    [options, onChange, displayUnit],
  );

  const handleUnitChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const unit = e.target.value;
      const minutes = unit === 'hours' ? displayValue * 60 : displayValue;
      onChange({ ...options, duration_minutes: minutes });
    },
    [options, onChange, displayValue],
  );

  return (
    <div className='step-options'>
      <div className='step-options__label'>
        <FormattedMessage
          id='custom_feeds.step_options.time_based_label'
          defaultMessage='Remove posts after'
        />
      </div>
      <div className='step-options__row'>
        <input
          type='number'
          className='step-options__input step-options__input--short'
          min={1}
          value={displayValue}
          onChange={handleValueChange}
        />
        <select
          className='step-options__select'
          value={displayUnit}
          onChange={handleUnitChange}
        >
          <option value='minutes'>{intl.formatMessage(messages.unitMinutes)}</option>
          <option value='hours'>{intl.formatMessage(messages.unitHours)}</option>
        </select>
      </div>
    </div>
  );
};
