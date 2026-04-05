import { useCallback } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';

import { Icon } from 'mastodon/components/icon';

const messages = defineMessages({
  domainPlaceholder: {
    id: 'custom_feeds.step_options.domain_placeholder',
    defaultMessage: 'e.g. mastodon.social',
  },
  tagPlaceholder: {
    id: 'custom_feeds.step_options.tag_placeholder',
    defaultMessage: 'e.g. rustlang',
  },
  removeServer: {
    id: 'custom_feeds.step_options.remove_server',
    defaultMessage: 'Remove server',
  },
});

interface SourceEntry {
  domain: string;
  tag: string;
}

interface RowProps {
  entry: SourceEntry;
  index: number;
  showRemove: boolean;
  onDomainChange: (index: number, value: string) => void;
  onTagChange: (index: number, value: string) => void;
  onRemove: (index: number) => void;
}

const SourceRow: React.FC<RowProps> = ({ entry, index, showRemove, onDomainChange, onTagChange, onRemove }) => {
  const intl = useIntl();

  const handleDomain = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => { onDomainChange(index, e.target.value); },
    [onDomainChange, index],
  );
  const handleTag = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => { onTagChange(index, e.target.value); },
    [onTagChange, index],
  );
  const handleRemove = useCallback(() => { onRemove(index); }, [onRemove, index]);

  return (
    <div className='step-options__row'>
      <input
        type='text'
        className='step-options__input'
        placeholder={intl.formatMessage(messages.domainPlaceholder)}
        value={entry.domain}
        onChange={handleDomain}
      />
      <span className='step-options__sep'>#</span>
      <input
        type='text'
        className='step-options__input'
        placeholder={intl.formatMessage(messages.tagPlaceholder)}
        value={entry.tag}
        onChange={handleTag}
      />
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

interface Props {
  options: Record<string, unknown>;
  onChange: (options: Record<string, unknown>) => void;
}

export const RemoteTagTimelineOptions: React.FC<Props> = ({ options, onChange }) => {
  const sources = (options.sources as SourceEntry[] | undefined) ?? [{ domain: '', tag: '' }];
  const limitPerRun = (options.limit_per_run as number | undefined) ?? 40;

  const updateSources = useCallback(
    (next: SourceEntry[]) => { onChange({ ...options, sources: next }); },
    [options, onChange],
  );

  const handleDomainChange = useCallback(
    (index: number, value: string) => {
      updateSources(sources.map((s, i) => (i === index ? { ...s, domain: value } : s)));
    },
    [sources, updateSources],
  );

  const handleTagChange = useCallback(
    (index: number, value: string) => {
      updateSources(sources.map((s, i) => (i === index ? { ...s, tag: value.replace(/^#/, '') } : s)));
    },
    [sources, updateSources],
  );

  const handleRemoveRow = useCallback(
    (index: number) => { updateSources(sources.filter((_, i) => i !== index)); },
    [sources, updateSources],
  );

  const handleAddRow = useCallback(() => {
    updateSources([...sources, { domain: '', tag: '' }]);
  }, [sources, updateSources]);

  const handleLimitChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange({ ...options, limit_per_run: parseInt(e.target.value, 10) || 40 });
    },
    [options, onChange],
  );

  return (
    <div className='step-options'>
      <div className='step-options__label'>
        <FormattedMessage id='custom_feeds.step_options.sources_label' defaultMessage='Servers to follow' />
      </div>

      {sources.map((entry, index) => (
        <SourceRow
          key={index}
          entry={entry}
          index={index}
          showRemove={sources.length > 1}
          onDomainChange={handleDomainChange}
          onTagChange={handleTagChange}
          onRemove={handleRemoveRow}
        />
      ))}

      <button type='button' className='step-options__add-btn' onClick={handleAddRow}>
        <FormattedMessage id='custom_feeds.step_options.add_server' defaultMessage='Add server' />
      </button>

      <div className='step-options__field'>
        <label htmlFor='cf-tag-limit'>
          <FormattedMessage id='custom_feeds.step_options.limit_per_run' defaultMessage='Posts fetched per run' />
        </label>
        <input
          id='cf-tag-limit'
          type='number'
          className='step-options__number'
          min={1}
          max={80}
          value={limitPerRun}
          onChange={handleLimitChange}
        />
      </div>
    </div>
  );
};
