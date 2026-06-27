CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_one_open_per_device
ON sessions(device_id)
WHERE status IN ('pending', 'active');
