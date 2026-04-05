import { useCallback } from 'react';

import { FormattedMessage } from 'react-intl';

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const FriendsLikedOptions: React.FC<Props> = ({ options, onChange }) => {
  const minInteractions = (options.min_interactions as number | undefined) ?? 1;

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({ ...options, min_interactions: parseInt(e.target.value, 10) || 1 });
    },
    [options, onChange],
  );

  return (
    <div className='step-options'>
      <div className='step-options__field'>
        <label htmlFor='cf-min-interactions'>
          <FormattedMessage
            id='custom_feeds.step_options.min_interactions'
            defaultMessage='Minimum interactions from follows'
          />
        </label>
        <input
          id='cf-min-interactions'
          type='number'
          className='step-options__number'
          min={1}
          value={minInteractions}
          onChange={handleChange}
        />
      </div>
    </div>
  );
};
