import { useState, useEffect, useCallback } from 'react';

import { defineMessages, useIntl } from 'react-intl';

import { Helmet } from 'react-helmet';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';
import EditIcon from '@/material-icons/400-24px/edit.svg?react';
import {
  apiGetSignals,
  apiUpdateSignal,
  apiDeleteSignal,
  apiDeleteAllSignals,
} from 'mastodon/api/recommendation_signals';
import type { ApiRecommendationSignalJSON } from 'mastodon/api/recommendation_signals';
import { Column } from 'mastodon/components/column';
import { ColumnHeader } from 'mastodon/components/column_header';
import { Icon } from 'mastodon/components/icon';
import { LoadingIndicator } from 'mastodon/components/loading_indicator';

const messages = defineMessages({
  heading: {
    id: 'custom_feeds.signals.heading',
    defaultMessage: 'Algorithm Signals',
  },
  tags: { id: 'custom_feeds.signals.tags', defaultMessage: 'Tags' },
  accounts: { id: 'custom_feeds.signals.accounts', defaultMessage: 'Accounts' },
  domains: { id: 'custom_feeds.signals.domains', defaultMessage: 'Domains' },
  textPhrases: {
    id: 'custom_feeds.signals.text_phrases',
    defaultMessage: 'Text phrases',
  },
  altTextPhrases: {
    id: 'custom_feeds.signals.alt_text_phrases',
    defaultMessage: 'Alt text phrases',
  },
  weight: { id: 'custom_feeds.signals.weight', defaultMessage: 'Weight' },
  observations: {
    id: 'custom_feeds.signals.observations',
    defaultMessage: 'Observations',
  },
  lastSeen: {
    id: 'custom_feeds.signals.last_seen',
    defaultMessage: 'Last seen',
  },
  edit: { id: 'custom_feeds.signals.edit', defaultMessage: 'Edit weight' },
  delete: {
    id: 'custom_feeds.signals.delete',
    defaultMessage: 'Delete signal',
  },
  deleteAll: {
    id: 'custom_feeds.signals.delete_all',
    defaultMessage: 'Delete all signals',
  },
  confirmDeleteAll: {
    id: 'custom_feeds.signals.confirm_delete_all',
    defaultMessage: 'Delete all {count} signals? This cannot be undone.',
  },
  save: { id: 'custom_feeds.signals.save', defaultMessage: 'Save' },
  cancel: { id: 'custom_feeds.signals.cancel', defaultMessage: 'Cancel' },
  noSignals: {
    id: 'custom_feeds.signals.no_signals',
    defaultMessage:
      'No signals yet. Interact with posts (boost, reply, like) in an algorithmic feed to build up signal data.',
  },
});

type SignalsByType = Record<
  ApiRecommendationSignalJSON['signal_type'],
  ApiRecommendationSignalJSON[]
>;

const SignalRow: React.FC<{
  signal: ApiRecommendationSignalJSON;
  onUpdate: (id: string, weight: number) => void;
  onDelete: (id: string) => void;
}> = ({ signal, onUpdate, onDelete }) => {
  const intl = useIntl();
  const [editing, setEditing] = useState(false);
  const [weight, setWeight] = useState(String(signal.weight));

  const handleEdit = useCallback(() => {
    setEditing(true);
    setWeight(String(signal.weight));
  }, [signal.weight]);
  const handleCancel = useCallback(() => {
    setEditing(false);
  }, []);

  const handleSave = useCallback(() => {
    const parsed = parseFloat(weight);
    if (!Number.isNaN(parsed) && parsed >= 0) {
      onUpdate(signal.id, parsed);
    }
    setEditing(false);
  }, [weight, signal.id, onUpdate]);

  const handleDelete = useCallback(() => {
    onDelete(signal.id);
  }, [signal.id, onDelete]);

  const handleWeightChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setWeight(e.target.value);
    },
    [],
  );

  const handleWeightKey = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter') handleSave();
      if (e.key === 'Escape') handleCancel();
    },
    [handleSave, handleCancel],
  );

  return (
    <div className='signals__row'>
      <span className='signals__row__entity'>{signal.entity_id}</span>

      {editing ? (
        <span className='signals__row__weight-edit'>
          <input
            type='number'
            className='step-options__input'
            value={weight}
            min={0}
            step={0.1}
            onChange={handleWeightChange}
            onKeyDown={handleWeightKey}
          />
          <button
            type='button'
            className='button button--small'
            onClick={handleSave}
          >
            {intl.formatMessage(messages.save)}
          </button>
          <button
            type='button'
            className='button button--small button-secondary'
            onClick={handleCancel}
          >
            {intl.formatMessage(messages.cancel)}
          </button>
        </span>
      ) : (
        <span className='signals__row__weight'>{signal.weight.toFixed(2)}</span>
      )}

      <span className='signals__row__observations'>
        {signal.observation_count}
      </span>

      <span className='signals__row__actions'>
        {!editing && (
          <button
            type='button'
            className='icon-button'
            title={intl.formatMessage(messages.edit)}
            aria-label={intl.formatMessage(messages.edit)}
            onClick={handleEdit}
          >
            <Icon id='edit' icon={EditIcon} />
          </button>
        )}
        <button
          type='button'
          className='icon-button icon-button--destructive'
          title={intl.formatMessage(messages.delete)}
          aria-label={intl.formatMessage(messages.delete)}
          onClick={handleDelete}
        >
          <Icon id='delete' icon={DeleteIcon} />
        </button>
      </span>
    </div>
  );
};

const SignalSection: React.FC<{
  title: string;
  signals: ApiRecommendationSignalJSON[];
  onUpdate: (id: string, weight: number) => void;
  onDelete: (id: string) => void;
}> = ({ title, signals, onUpdate, onDelete }) => {
  const intl = useIntl();

  if (signals.length === 0) return null;

  return (
    <div className='signals__section'>
      <h3 className='signals__section__heading'>{title}</h3>
      <div className='signals__table'>
        <div className='signals__row signals__row--header'>
          <span className='signals__row__entity' />
          <span className='signals__row__weight'>
            {intl.formatMessage(messages.weight)}
          </span>
          <span className='signals__row__observations'>
            {intl.formatMessage(messages.observations)}
          </span>
          <span className='signals__row__actions' />
        </div>
        {signals.map((s) => (
          <SignalRow
            key={s.id}
            signal={s}
            onUpdate={onUpdate}
            onDelete={onDelete}
          />
        ))}
      </div>
    </div>
  );
};

export const CustomFeedsSignals: React.FC<{ multiColumn?: boolean }> = ({
  multiColumn,
}) => {
  const intl = useIntl();
  const [signals, setSignals] = useState<ApiRecommendationSignalJSON[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void apiGetSignals()
      .then((data) => {
        setSignals(data);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, []);

  const handleUpdate = useCallback((id: string, weight: number) => {
    void apiUpdateSignal(id, weight).then((updated) => {
      setSignals((prev) => prev.map((s) => (s.id === id ? updated : s)));
    });
  }, []);

  const handleDelete = useCallback((id: string) => {
    void apiDeleteSignal(id).then(() => {
      setSignals((prev) => prev.filter((s) => s.id !== id));
    });
  }, []);

  const handleDeleteAll = useCallback(() => {
    const msg = intl.formatMessage(messages.confirmDeleteAll, {
      count: signals.length,
    });
    if (!window.confirm(msg)) return;
    void apiDeleteAllSignals().then(() => {
      setSignals([]);
    });
  }, [intl, signals.length]);

  const byType = signals.reduce<SignalsByType>(
    (acc, s) => {
      acc[s.signal_type] = [...acc[s.signal_type], s];
      return acc;
    },
    { tag: [], account: [], domain: [], text_phrase: [], alt_text_phrase: [] },
  );

  return (
    <Column
      bindToDocument={!multiColumn}
      label={intl.formatMessage(messages.heading)}
    >
      <ColumnHeader
        title={intl.formatMessage(messages.heading)}
        icon='tune'
        showBackButton
        multiColumn={multiColumn}
      />

      <div className='scrollable signals'>
        {loading ? (
          <LoadingIndicator />
        ) : signals.length === 0 ? (
          <div className='empty-column-indicator'>
            {intl.formatMessage(messages.noSignals)}
          </div>
        ) : (
          <>
            <SignalSection
              title={intl.formatMessage(messages.tags)}
              signals={byType.tag}
              onUpdate={handleUpdate}
              onDelete={handleDelete}
            />
            <SignalSection
              title={intl.formatMessage(messages.accounts)}
              signals={byType.account}
              onUpdate={handleUpdate}
              onDelete={handleDelete}
            />
            <SignalSection
              title={intl.formatMessage(messages.domains)}
              signals={byType.domain}
              onUpdate={handleUpdate}
              onDelete={handleDelete}
            />
            <SignalSection
              title={intl.formatMessage(messages.textPhrases)}
              signals={byType.text_phrase}
              onUpdate={handleUpdate}
              onDelete={handleDelete}
            />
            <SignalSection
              title={intl.formatMessage(messages.altTextPhrases)}
              signals={byType.alt_text_phrase}
              onUpdate={handleUpdate}
              onDelete={handleDelete}
            />

            <div className='signals__footer'>
              <button
                type='button'
                className='button button--destructive'
                onClick={handleDeleteAll}
              >
                <Icon id='delete' icon={DeleteIcon} />{' '}
                {intl.formatMessage(messages.deleteAll)}
              </button>
            </div>
          </>
        )}
      </div>

      <Helmet>
        <title>{intl.formatMessage(messages.heading)}</title>
        <meta name='robots' content='noindex' />
      </Helmet>
    </Column>
  );
};

// eslint-disable-next-line import/no-default-export
export default CustomFeedsSignals;
