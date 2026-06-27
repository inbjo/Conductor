UPDATE sessions
SET status = 'superseded', closed_at = COALESCE(closed_at, datetime('now'))
WHERE status IN ('pending', 'active')
  AND session_id NOT IN (
    SELECT session_id
    FROM (
      SELECT
        session_id,
        ROW_NUMBER() OVER (
          PARTITION BY device_id
          ORDER BY created_at DESC, session_id DESC
        ) AS rank
      FROM sessions
      WHERE status IN ('pending', 'active')
    )
    WHERE rank = 1
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_one_open_per_device
ON sessions(device_id)
WHERE status IN ('pending', 'active');
