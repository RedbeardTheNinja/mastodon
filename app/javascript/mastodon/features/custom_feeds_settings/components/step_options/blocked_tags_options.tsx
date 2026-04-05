import { useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';

import { Icon } from 'mastodon/components/icon';

const messages = defineMessages({
  tagPlaceholder: {
    id: 'custom_feeds.step_options.blocked_tag_placeholder',
    defaultMessage: 'e.g. politics',
  },
  removeTag: {
    id: 'custom_feeds.step_options.remove_tag',
    defaultMessage: 'Remove tag',
  },
});

interface RowProps {
  tag: string;
  index: number;
  showRemove: boolean;
  onChange: (index: number, value: string) => void;
  onRemove: (index: number) => void;
}

const TagRow: React.FC<RowProps> = ({ tag, index, showRemove, onChange, onRemove }) => {
  const intl = useIntl();

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => { onChange(index, e.target.value); },
    [onChange, index],
  );
  const handleRemove = useCallback(() => { onRemove(index); }, [onRemove, index]);

  return (
    <div className='step-options__row'>
      <span className='step-options__sep'>#</span>
      <input
        type='text'
        className='step-options__input'
        placeholder={intl.formatMessage(messages.tagPlaceholder)}
        value={tag.replace(/^#/, '')}
        onChange={handleChange}
      />
      {showRemove && (
        <button
          type='button'
          className='icon-button icon-button--destructive'
          title={intl.formatMessage(messages.removeTag)}
          aria-label={intl.formatMessage(messages.removeTag)}
          onClick={handleRemove}
        >
          <Icon id='delete' icon={DeleteIcon} />
        </button>
      )}
    </div>
  );
};

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const BlockedTagsOptions: React.FC<Props> = ({ options, onChange }) => {
  const tags = (options.tags as string[] | undefined) ?? [''];

  const handleTagChange = useCallback(
    (index: number, value: string) => {
      const next = tags.map((t, i) => (i === index ? value.replace(/^#/, '') : t));
      onChange({ ...options, tags: next });
    },
    [tags, options, onChange],
  );

  const handleRemove = useCallback(
    (index: number) => {
      onChange({ ...options, tags: tags.filter((_, i) => i !== index) });
    },
    [tags, options, onChange],
  );

  const handleAdd = useCallback(() => {
    onChange({ ...options, tags: [...tags, ''] });
  }, [tags, options, onChange]);

  return (
    <div className='step-options'>
      <div className='step-options__label'>
        <FormattedMessage
          id='custom_feeds.step_options.blocked_tags_label'
          defaultMessage='Tags to block'
        />
      </div>

      {tags.map((tag, index) => (
        <TagRow
          key={index}
          tag={tag}
          index={index}
          showRemove={tags.length > 1}
          onChange={handleTagChange}
          onRemove={handleRemove}
        />
      ))}

      <button type='button' className='step-options__add-btn' onClick={handleAdd}>
        <FormattedMessage
          id='custom_feeds.step_options.add_tag'
          defaultMessage='Add tag'
        />
      </button>
    </div>
  );
};
