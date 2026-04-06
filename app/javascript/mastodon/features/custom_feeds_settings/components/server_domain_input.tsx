import { useState, useCallback, useRef, useEffect, useId } from 'react';

import { useIntl, defineMessages } from 'react-intl';

import {
  KNOWN_SERVERS,
  CATEGORY_LABELS
  
} from '../data/known_servers';
import type {KnownServer} from '../data/known_servers';

const messages = defineMessages({
  filterPlaceholder: {
    id: 'custom_feeds.server_picker.filter_placeholder',
    defaultMessage: 'Search servers…',
  },
  manualEntry: {
    id: 'custom_feeds.server_picker.manual_entry',
    defaultMessage: 'Enter domain manually…',
  },
  backToList: {
    id: 'custom_feeds.server_picker.back_to_list',
    defaultMessage: '← Back to server list',
  },
  domainPlaceholder: {
    id: 'custom_feeds.step_options.domain_placeholder',
    defaultMessage: 'e.g. mastodon.social',
  },
  publicTimelineUnavailable: {
    id: 'custom_feeds.server_picker.public_timeline_unavailable',
    defaultMessage: 'Public timeline not available without login',
  },
});

interface Props {
  value: string;
  onChange: (value: string) => void;
  /** When true, marks servers that don't support unauthenticated public timeline */
  warnNonPublic?: boolean;
}

const MAX_RESULTS = 30;

// ---------------------------------------------------------------------------
// Server option row — extracted to avoid arrow functions in JSX props
// ---------------------------------------------------------------------------

interface ServerOptionProps {
  server: KnownServer;
  selected: boolean;
  onSelect: (server: KnownServer) => void;
}

const ServerOption: React.FC<ServerOptionProps> = ({
  server,
  selected,
  onSelect,
}) => {
  const handleMouseDown = useCallback(() => {
    onSelect(server);
  }, [onSelect, server]);

  return (
    <li
      role='option'
      aria-selected={selected}
      className={`server-domain-input__option${selected ? ' server-domain-input__option--selected' : ''}`}
      onMouseDown={handleMouseDown}
    >
      <span className='server-domain-input__option-domain'>
        {server.domain}
      </span>
      <span className='server-domain-input__option-category'>
        {CATEGORY_LABELS[server.category] ?? server.category}
      </span>
    </li>
  );
};

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export const ServerDomainInput: React.FC<Props> = ({
  value,
  onChange,
  warnNonPublic = false,
}) => {
  const intl = useIntl();
  const listboxId = useId();
  const filterRef = useRef<HTMLInputElement>(null);

  const [manual, setManual] = useState(() => {
    // Start in manual mode if the current value isn't in the known list
    return value !== '' && !KNOWN_SERVERS.some((s) => s.domain === value);
  });
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState('');
  const containerRef = useRef<HTMLDivElement>(null);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (
        containerRef.current &&
        !containerRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => { document.removeEventListener('mousedown', handler); };
  }, []);

  // Focus filter input when dropdown opens
  useEffect(() => {
    if (open) {
      filterRef.current?.focus();
    }
  }, [open]);

  const filtered = filter
    ? KNOWN_SERVERS.filter((s) => s.domain.includes(filter.toLowerCase()))
    : KNOWN_SERVERS;

  const results = filtered.slice(0, MAX_RESULTS);

  const handleSelect = useCallback(
    (server: KnownServer) => {
      onChange(server.domain);
      setOpen(false);
      setFilter('');
    },
    [onChange],
  );

  const handleSwitchToManual = useCallback(() => {
    setManual(true);
    setOpen(false);
    setFilter('');
  }, []);

  const handleSwitchToList = useCallback(() => {
    setManual(false);
    onChange('');
  }, [onChange]);

  const handleManualChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange(e.target.value);
    },
    [onChange],
  );

  const handleButtonClick = useCallback(() => {
    setOpen((prev) => !prev);
  }, []);

  const handleFilterChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setFilter(e.target.value);
    },
    [],
  );

  const selectedServer = KNOWN_SERVERS.find((s) => s.domain === value);
  const showWarning =
    warnNonPublic && selectedServer && !selectedServer.publicTimeline;

  if (manual) {
    return (
      <div className='server-domain-input server-domain-input--manual'>
        <input
          type='text'
          className='step-options__input'
          placeholder={intl.formatMessage(messages.domainPlaceholder)}
          value={value}
          onChange={handleManualChange}
        />
        <button
          type='button'
          className='server-domain-input__back'
          onClick={handleSwitchToList}
        >
          {intl.formatMessage(messages.backToList)}
        </button>
      </div>
    );
  }

  return (
    <div className='server-domain-input' ref={containerRef}>
      <button
        type='button'
        className='server-domain-input__trigger'
        aria-haspopup='listbox'
        aria-expanded={open}
        aria-controls={listboxId}
        onClick={handleButtonClick}
      >
        {value ? (
          <span className='server-domain-input__selected'>
            {value}
            {selectedServer && (
              <span className='server-domain-input__category'>
                {CATEGORY_LABELS[selectedServer.category] ??
                  selectedServer.category}
              </span>
            )}
          </span>
        ) : (
          <span className='server-domain-input__placeholder'>
            {intl.formatMessage(messages.filterPlaceholder)}
          </span>
        )}
      </button>

      {showWarning && (
        <span className='server-domain-input__warning'>
          {intl.formatMessage(messages.publicTimelineUnavailable)}
        </span>
      )}

      {open && (
        <div
          className='server-domain-input__dropdown'
          id={listboxId}
          role='listbox'
        >
          <input
            ref={filterRef}
            type='text'
            className='server-domain-input__filter'
            placeholder={intl.formatMessage(messages.filterPlaceholder)}
            value={filter}
            onChange={handleFilterChange}
          />

          <ul className='server-domain-input__list'>
            {results.map((server) => (
              <ServerOption
                key={server.domain}
                server={server}
                selected={server.domain === value}
                onSelect={handleSelect}
              />
            ))}

            {results.length === 0 && (
              <li
                className='server-domain-input__no-results'
                role='option'
                aria-selected={false}
              >
                {filter}
              </li>
            )}

            <li
              role='option'
              aria-selected={false}
              className='server-domain-input__manual-option'
              onMouseDown={handleSwitchToManual}
            >
              {intl.formatMessage(messages.manualEntry)}
            </li>
          </ul>
        </div>
      )}
    </div>
  );
};
