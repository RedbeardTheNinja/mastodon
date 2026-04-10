import { useCallback, useEffect, useState } from 'react';

import { defineMessages, useIntl, FormattedMessage } from 'react-intl';

import { Helmet } from 'react-helmet';
import { Link } from 'react-router-dom';

import AddIcon from '@/material-icons/400-24px/add.svg?react';
import AdminPanelIcon from '@/material-icons/400-24px/badge.svg?react';
import SettingsIcon from '@/material-icons/400-24px/settings.svg?react';
import TuneIcon from '@/material-icons/400-24px/tune.svg?react';
import SquigglyArrow from '@/svg-icons/squiggly_arrow.svg?react';
import { fetchCustomFeeds } from 'mastodon/actions/custom_feeds';
import { fetchLists } from 'mastodon/actions/lists_typed';
import type { ApiCustomFeedConfigJSON } from 'mastodon/api_types/custom_feeds';
import { Column } from 'mastodon/components/column';
import { ColumnHeader } from 'mastodon/components/column_header';
import { Icon } from 'mastodon/components/icon';
import ScrollableList from 'mastodon/components/scrollable_list';
import { useIdentity } from 'mastodon/identity_context';
import { PERMISSION_MANAGE_USERS } from 'mastodon/permissions';
import { useAppDispatch, useAppSelector } from 'mastodon/store';

import { CustomFeedCard } from './components/custom_feed_card';
import { CustomFeedForm } from './components/custom_feed_form';

const messages = defineMessages({
  heading: {
    id: 'custom_feeds.heading',
    defaultMessage: 'Custom Feeds',
  },
  addFeed: {
    id: 'custom_feeds.add_feed',
    defaultMessage: 'Add custom feed',
  },
  signals: {
    id: 'custom_feeds.signals_settings',
    defaultMessage: 'Algorithm signals',
  },
  adminSignals: {
    id: 'custom_feeds.admin_signals',
    defaultMessage: 'Admin: signals & feeds',
  },
});

const CustomFeedsSettings: React.FC<{ multiColumn?: boolean }> = ({
  multiColumn,
}) => {
  const dispatch = useAppDispatch();
  const intl = useIntl();
  const { permissions } = useIdentity();
  const isAdmin =
    (permissions & PERMISSION_MANAGE_USERS) === PERMISSION_MANAGE_USERS;
  const [adding, setAdding] = useState(false);

  const handleStartAdding = useCallback(() => {
    setAdding(true);
  }, []);
  const handleStopAdding = useCallback(() => {
    setAdding(false);
  }, []);

  const configs = useAppSelector((state) => {
    const map = state.customFeeds as unknown as {
      valueSeq: () => Iterable<ApiCustomFeedConfigJSON | null>;
      size: number;
    };
    return [...map.valueSeq()].filter(
      (c): c is ApiCustomFeedConfigJSON => c !== null,
    );
  });

  useEffect(() => {
    void dispatch(fetchLists());
    void dispatch(fetchCustomFeeds());
  }, [dispatch]);

  const emptyMessage = adding ? null : (
    <>
      <span>
        <FormattedMessage
          id='custom_feeds.no_feeds_yet'
          defaultMessage='No custom feeds yet.'
        />
        <br />
        <FormattedMessage
          id='custom_feeds.no_feeds_hint'
          defaultMessage='Create one to filter your feed using a list.'
        />
      </span>
      <SquigglyArrow className='empty-column-indicator__arrow' />
    </>
  );

  return (
    <Column
      bindToDocument={!multiColumn}
      label={intl.formatMessage(messages.heading)}
    >
      <ColumnHeader
        title={intl.formatMessage(messages.heading)}
        icon='tune'
        iconComponent={TuneIcon}
        multiColumn={multiColumn}
        extraButton={
          <span className='column-header__buttons'>
            {!adding && (
              <button
                type='button'
                className='column-header__button'
                title={intl.formatMessage(messages.addFeed)}
                aria-label={intl.formatMessage(messages.addFeed)}
                onClick={handleStartAdding}
              >
                <Icon id='plus' icon={AddIcon} />
              </button>
            )}
            <Link
              to='/custom_feeds/signals'
              className='column-header__button'
              title={intl.formatMessage(messages.signals)}
              aria-label={intl.formatMessage(messages.signals)}
            >
              <Icon id='settings' icon={SettingsIcon} />
            </Link>
            {isAdmin && (
              <a
                href='/admin/recommendation_signals'
                className='column-header__button'
                title={intl.formatMessage(messages.adminSignals)}
                aria-label={intl.formatMessage(messages.adminSignals)}
              >
                <Icon id='badge' icon={AdminPanelIcon} />
              </a>
            )}
          </span>
        }
      />

      <ScrollableList
        scrollKey='custom_feeds'
        emptyMessage={emptyMessage}
        bindToDocument={!multiColumn}
        prepend={
          adding && (
            <div className='custom-feed-new'>
              <CustomFeedForm onClose={handleStopAdding} />
            </div>
          )
        }
        alwaysPrepend={adding}
      >
        {configs.map((config) => (
          <CustomFeedCard key={config.id} config={config} />
        ))}
      </ScrollableList>

      <Helmet>
        <title>{intl.formatMessage(messages.heading)}</title>
        <meta name='robots' content='noindex' />
      </Helmet>
    </Column>
  );
};

// eslint-disable-next-line import/no-default-export
export default CustomFeedsSettings;
