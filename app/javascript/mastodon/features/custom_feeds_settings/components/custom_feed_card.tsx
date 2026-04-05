import { useCallback, useState } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import DeleteIcon from '@/material-icons/400-24px/delete.svg?react';
import EditIcon from '@/material-icons/400-24px/edit.svg?react';
import TuneIcon from '@/material-icons/400-24px/tune.svg?react';

import { deleteCustomFeed } from 'mastodon/actions/custom_feeds';
import { Icon } from 'mastodon/components/icon';
import { useAppDispatch, useAppSelector } from 'mastodon/store';

import type { ApiCustomFeedConfigJSON } from 'mastodon/api_types/custom_feeds';

import { CustomFeedForm } from './custom_feed_form';

const messages = defineMessages({
  edit:   { id: 'custom_feeds.card.edit',   defaultMessage: 'Edit' },
  delete: { id: 'custom_feeds.card.delete', defaultMessage: 'Delete' },
});

interface Props {
  config: ApiCustomFeedConfigJSON;
}

export const CustomFeedCard: React.FC<Props> = ({ config }) => {
  const dispatch = useAppDispatch();
  const intl = useIntl();
  const [editing, setEditing] = useState(false);

  const list = useAppSelector((state) =>
    (
      state.lists as unknown as {
        get: (id: string) => { id: string; title: string } | undefined;
      }
    ).get(config.list_id),
  );

  const handleDelete = useCallback(() => {
    void dispatch(deleteCustomFeed({ id: config.id }));
  }, [dispatch, config]);

  const handleStartEditing = useCallback(() => { setEditing(true); }, []);
  const handleStopEditing  = useCallback(() => { setEditing(false); }, []);

  if (editing) {
    return (
      <div className='custom-feed-card--editing'>
        <div className='custom-feed-card--editing__header'>
          <Icon id='tune' icon={TuneIcon} />
          <strong>{list?.title ?? config.list_id}</strong>
        </div>
        <CustomFeedForm config={config} onClose={handleStopEditing} />
      </div>
    );
  }

  return (
    <div className='lists__item'>
      <div className='lists__item__title'>
        <Icon id='tune' icon={TuneIcon} />
        <span>{list?.title ?? config.list_id}</span>
        {!config.enabled && (
          <span className='custom-feed-card__disabled-badge'>
            <FormattedMessage
              id='custom_feeds.card.disabled'
              defaultMessage='Disabled'
            />
          </span>
        )}
      </div>

      <div className='custom-feed-card__actions'>
        <button
          type='button'
          className='icon-button'
          title={intl.formatMessage(messages.edit)}
          aria-label={intl.formatMessage(messages.edit)}
          onClick={handleStartEditing}
        >
          <Icon id='edit' icon={EditIcon} />
        </button>
        <button
          type='button'
          className='icon-button icon-button--destructive'
          title={intl.formatMessage(messages.delete)}
          aria-label={intl.formatMessage(messages.delete)}
          onClick={handleDelete}
        >
          <Icon id='delete' icon={DeleteIcon} />
        </button>
      </div>
    </div>
  );
};
