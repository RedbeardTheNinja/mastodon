import { useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';
import { Icon } from 'mastodon/components/icon';

import { ServerDomainInput } from '../server_domain_input';

const messages = defineMessages({
  tagPlaceholder: {
    id: 'custom_feeds.step_options.tag_placeholder',
    defaultMessage: 'e.g. rustlang',
  },
  removeTag: {
    id: 'custom_feeds.step_options.remove_tag',
    defaultMessage: 'Remove tag',
  },
  removeServer: {
    id: 'custom_feeds.step_options.remove_server',
    defaultMessage: 'Remove server',
  },
});

// ---------------------------------------------------------------------------
// Tag row
// ---------------------------------------------------------------------------

interface TagRowProps {
  value: string;
  index: number;
  showRemove: boolean;
  onChange: (index: number, value: string) => void;
  onRemove: (index: number) => void;
}

const TagRow: React.FC<TagRowProps> = ({
  value,
  index,
  showRemove,
  onChange,
  onRemove,
}) => {
  const intl = useIntl();

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange(index, e.target.value.replace(/^#/, ''));
    },
    [onChange, index],
  );

  const handleRemove = useCallback(() => {
    onRemove(index);
  }, [onRemove, index]);

  return (
    <div className='step-options__source-row'>
      <span className='step-options__sep'>#</span>
      <input
        type='text'
        className='step-options__input'
        placeholder={intl.formatMessage(messages.tagPlaceholder)}
        value={value}
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

// ---------------------------------------------------------------------------
// Domain row
// ---------------------------------------------------------------------------

interface DomainRowProps {
  value: string;
  index: number;
  showRemove: boolean;
  onChange: (index: number, value: string) => void;
  onRemove: (index: number) => void;
}

const DomainRow: React.FC<DomainRowProps> = ({
  value,
  index,
  showRemove,
  onChange,
  onRemove,
}) => {
  const intl = useIntl();

  const handleChange = useCallback(
    (v: string) => {
      onChange(index, v);
    },
    [onChange, index],
  );

  const handleRemove = useCallback(() => {
    onRemove(index);
  }, [onRemove, index]);

  return (
    <div className='step-options__source-row'>
      <ServerDomainInput value={value} onChange={handleChange} />
      {showRemove && (
        <button
          type='button'
          className='icon-button icon-button--destructive'
          title={intl.formatMessage(messages.removeServer)}
          aria-label={intl.formatMessage(messages.removeServer)}
          onClick={handleRemove}
        >
          <Icon id='delete' icon={DeleteIcon} />
        </button>
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Main options component
// ---------------------------------------------------------------------------

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const RemoteTagTimelineOptions: React.FC<Props> = ({
  options,
  onChange,
}) => {
  const tags = (options.tags as string[] | undefined) ?? [''];
  const domains = (options.domains as string[] | undefined) ?? [''];
  const limitPerRun = (options.limit_per_run as number | undefined) ?? 40;

  const handleTagChange = useCallback(
    (index: number, value: string) => {
      onChange({
        ...options,
        tags: tags.map((t, i) => (i === index ? value : t)),
      });
    },
    [options, onChange, tags],
  );

  const handleAddTag = useCallback(() => {
    onChange({ ...options, tags: [...tags, ''] });
  }, [options, onChange, tags]);

  const handleRemoveTag = useCallback(
    (index: number) => {
      onChange({ ...options, tags: tags.filter((_, i) => i !== index) });
    },
    [options, onChange, tags],
  );

  const handleDomainChange = useCallback(
    (index: number, value: string) => {
      onChange({
        ...options,
        domains: domains.map((d, i) => (i === index ? value : d)),
      });
    },
    [options, onChange, domains],
  );

  const handleAddDomain = useCallback(() => {
    onChange({ ...options, domains: [...domains, ''] });
  }, [options, onChange, domains]);

  const handleRemoveDomain = useCallback(
    (index: number) => {
      onChange({
        ...options,
        domains: domains.filter((_, i) => i !== index),
      });
    },
    [options, onChange, domains],
  );

  const handleLimitChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({
        ...options,
        limit_per_run: parseInt(e.target.value, 10) || 40,
      });
    },
    [options, onChange],
  );

  return (
    <div className='step-options'>
      <div className='step-options__label'>
        <FormattedMessage
          id='custom_feeds.step_options.tags_label'
          defaultMessage='Tags to follow'
        />
      </div>

      {tags.map((tag, index) => (
        <TagRow
          key={index}
          value={tag}
          index={index}
          showRemove={tags.length > 1}
          onChange={handleTagChange}
          onRemove={handleRemoveTag}
        />
      ))}

      <button
        type='button'
        className='step-options__add-btn'
        onClick={handleAddTag}
      >
        <FormattedMessage
          id='custom_feeds.step_options.add_tag'
          defaultMessage='Add tag'
        />
      </button>

      <div className='step-options__label'>
        <FormattedMessage
          id='custom_feeds.step_options.servers_label'
          defaultMessage='Servers to fetch from'
        />
      </div>

      {domains.map((domain, index) => (
        <DomainRow
          key={index}
          value={domain}
          index={index}
          showRemove={domains.length > 1}
          onChange={handleDomainChange}
          onRemove={handleRemoveDomain}
        />
      ))}

      <button
        type='button'
        className='step-options__add-btn'
        onClick={handleAddDomain}
      >
        <FormattedMessage
          id='custom_feeds.step_options.add_server'
          defaultMessage='Add server'
        />
      </button>

      <div className='step-options__field'>
        <label htmlFor='cf-tag-limit'>
          <FormattedMessage
            id='custom_feeds.step_options.limit_per_run'
            defaultMessage='Posts fetched per run'
          />
        </label>
        <input
          id='cf-tag-limit'
          type='number'
          className='step-options__number'
          min={1}
          max={500}
          value={limitPerRun}
          onChange={handleLimitChange}
        />
      </div>
    </div>
  );
};
