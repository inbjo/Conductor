import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation, useNavigate, useParams } from 'react-router';
import { create } from 'zustand';
import {
  Activity,
  ChevronRight,
  Cable,
  CircleDot,
  FileDown,
  FolderOpen,
  FolderPlus,
  LogOut,
  MessageSquare,
  Mic,
  MicOff,
  MonitorDot,
  PhoneOff,
  RefreshCcw,
  Search,
  Send,
  ShieldCheck,
  Trash2,
  Upload,
  Volume2,
} from 'lucide-react';
import './styles.css';

type Device = {
  device_id: string;
  hostname: string;
  os: string;
  arch: string;
  username: string;
  agent_version: string;
  local_ip: string;
  online: number;
  last_heartbeat: string | null;
  updated_at: string;
};

type Session = {
  session_id: string;
  device_id: string;
  status: string;
  created_at: string;
  closed_at: string | null;
};

type AuditLog = {
  id: string;
  actor: string;
  action: string;
  target: string;
  detail: string;
  created_at: string;
};

type Overview = {
  total_devices: number;
  online_devices: number;
  active_sessions: number;
  total_sessions: number;
  audit_events: number;
  recent_devices: Device[];
  recent_sessions: Session[];
  recent_audit_logs: AuditLog[];
};

type Me = {
  username: string;
};

type FileEntry = {
  name: string;
  path: string;
  is_dir: boolean;
  size: number;
  modified: string | null;
};

type ChatMessage = {
  message_id: string;
  session_id: string;
  device_id: string;
  sender: string;
  text: string;
  created_at: string;
};

type ScreenFrame = {
  session_id: string;
  width: number;
  height: number;
  image_data_url: string;
  captured_at: string;
};

type ControlEventPayload = {
  type: 'control_event';
  session_id: string;
  kind: string;
  x?: number;
  y?: number;
  button?: string;
  key?: string;
  delta_x?: number;
  delta_y?: number;
  created_at: string;
};

type AdminEvent =
  | { type: 'agent_status_changed'; device_id: string; online: boolean }
  | { type: 'chat_message'; message_id: string; session_id: string; device_id: string; sender: string; text: string; created_at: string }
  | { type: 'session_status'; session_id: string; status: string }
  | { type: 'signal'; session_id: string; kind: string; payload: unknown }
  | ({ type: 'screen_frame' } & ScreenFrame)
  | ({ type: 'control_ack' } & Omit<ControlEventPayload, 'type'>)
  | { type: 'voice_status'; session_id: string; status: string; muted: boolean | null; reason: string | null };

type AuthStore = {
  token: string | null;
  setToken: (token: string | null) => void;
};

const useAuth = create<AuthStore>((set) => ({
  token: localStorage.getItem('conductor.token'),
  setToken: (token) => {
    if (token) localStorage.setItem('conductor.token', token);
    else localStorage.removeItem('conductor.token');
    set({ token });
  },
}));

type LiveStore = {
  frames: Record<string, ScreenFrame>;
  logs: Record<string, string[]>;
  signals: Record<string, { kind: string; payload: unknown; receivedAt: string }[]>;
  voice: Record<string, { status: string; muted: boolean; reason?: string | null }>;
  closedSessions: Record<string, string>;
  wsStatus: 'disconnected' | 'connecting' | 'connected';
  send: ((payload: unknown) => void) | null;
  setSend: (send: ((payload: unknown) => void) | null) => void;
  setWsStatus: (status: LiveStore['wsStatus']) => void;
  setFrame: (frame: ScreenFrame) => void;
  pushSignal: (sessionId: string, kind: string, payload: unknown) => void;
  setVoice: (sessionId: string, status: string, muted?: boolean | null, reason?: string | null) => void;
  closeSession: (sessionId: string, reason: string) => void;
  addLog: (sessionId: string, line: string) => void;
};

const useLive = create<LiveStore>((set) => ({
  frames: {},
  logs: {},
  signals: {},
  voice: {},
  closedSessions: {},
  wsStatus: 'disconnected',
  send: null,
  setSend: (send) => set({ send }),
  setWsStatus: (wsStatus) => set({ wsStatus }),
  setFrame: (frame) => set((state) => ({ frames: { ...state.frames, [frame.session_id]: frame } })),
  pushSignal: (sessionId, kind, payload) =>
    set((state) => ({
      signals: {
        ...state.signals,
        [sessionId]: [
          ...(state.signals[sessionId] || []),
          { kind, payload, receivedAt: new Date().toISOString() },
        ].slice(-20),
      },
    })),
  setVoice: (sessionId, status, muted, reason) =>
    set((state) => ({
      voice: {
        ...state.voice,
        [sessionId]: {
          status,
          muted: muted ?? state.voice[sessionId]?.muted ?? false,
          reason,
        },
      },
    })),
  closeSession: (sessionId, reason) =>
    set((state) => ({
      closedSessions: { ...state.closedSessions, [sessionId]: reason },
      logs: {
        ...state.logs,
        [sessionId]: [`session closed: ${reason}`, ...(state.logs[sessionId] || [])].slice(0, 12),
      },
    })),
  addLog: (sessionId, line) =>
    set((state) => ({
      logs: {
        ...state.logs,
        [sessionId]: [line, ...(state.logs[sessionId] || [])].slice(0, 12),
      },
    })),
}));

const queryClient = new QueryClient();

function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = useAuth.getState().token;
  const headers = new Headers(init.headers);
  if (token) headers.set('Authorization', `Bearer ${token}`);
  if (init.body && !(init.body instanceof FormData)) headers.set('Content-Type', 'application/json');
  return fetch(path, { ...init, headers }).then(async (res) => {
    if (res.status === 401) {
      useAuth.getState().setToken(null);
      throw new Error('登录已过期');
    }
    if (!res.ok) {
      const body = await res.json().catch(() => ({ error: res.statusText }));
      throw new Error(body.error || res.statusText);
    }
    return res.json() as Promise<T>;
  });
}

function AppShell() {
  const token = useAuth((s) => s.token);
  const wsStatus = useLive((s) => s.wsStatus);
  const me = useQuery({
    queryKey: ['me'],
    queryFn: () => api<Me>('/api/me'),
    enabled: Boolean(token),
  });
  useAdminSocket(token);

  if (!token) return <Navigate to="/login" replace />;

  return (
    <div className="min-h-screen bg-panel text-ink">
      <aside className="fixed inset-y-0 left-0 hidden w-64 border-r border-line bg-[#eef2eb] lg:block">
        <div className="flex h-16 items-center gap-3 border-b border-line px-5">
          <div className="grid h-10 w-10 place-items-center bg-ink text-white">
            <Cable size={20} />
          </div>
          <div>
            <div className="font-semibold tracking-wide">Conductor</div>
            <div className="text-xs text-ink/60">Remote Command Center</div>
          </div>
        </div>
        <nav className="space-y-2 p-4">
          <NavLink to="/" icon={<Activity size={18} />} label="概览" />
          <NavLink to="/devices" icon={<MonitorDot size={18} />} label="设备" />
          <NavLink to="/audit" icon={<ShieldCheck size={18} />} label="审计" />
        </nav>
      </aside>
      <main className="lg:pl-64">
        <header className="sticky top-0 z-10 flex h-16 items-center justify-between border-b border-line bg-panel/95 px-4 backdrop-blur lg:px-8">
          <div className="flex items-center gap-2 text-sm text-ink/70">
            <CircleDot size={16} className={wsStatus === 'connected' ? 'text-signal' : 'text-alert'} />
            集中式远程管理后台
            <span className="ws-pill">{wsStatus}</span>
          </div>
          <div className="flex items-center gap-3">
            <div className="user-chip">{me.data?.username || 'admin'}</div>
            <button
              className="icon-text"
              onClick={() => useAuth.getState().setToken(null)}
              title="退出登录"
            >
              <LogOut size={16} />
              退出
            </button>
          </div>
        </header>
        <Routes>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/devices" element={<DevicesPage />} />
          <Route path="/devices/:id" element={<DeviceDetailPage />} />
          <Route path="/sessions/:sessionId" element={<RemotePage />} />
          <Route path="/devices/:id/files" element={<FilesPage />} />
          <Route path="/audit" element={<AuditPage />} />
        </Routes>
      </main>
    </div>
  );
}

function NavLink({ to, icon, label, muted }: { to: string; icon: React.ReactNode; label: string; muted?: boolean }) {
  return (
    <Link className={`flex items-center gap-3 px-3 py-2 text-sm ${muted ? 'text-ink/40' : 'bg-white shadow-crisp'}`} to={to}>
      {icon}
      {label}
    </Link>
  );
}

function useAdminSocket(token: string | null) {
  const qc = useQueryClient();
  const setSend = useLive((s) => s.setSend);
  const setFrame = useLive((s) => s.setFrame);
  const pushSignal = useLive((s) => s.pushSignal);
  const setVoice = useLive((s) => s.setVoice);
  const closeSession = useLive((s) => s.closeSession);
  const setWsStatus = useLive((s) => s.setWsStatus);
  const addLog = useLive((s) => s.addLog);
  useEffect(() => {
    if (!token) {
      setWsStatus('disconnected');
      return;
    }
    let socket: WebSocket | null = null;
    let reconnectTimer: number | undefined;
    let stopped = false;
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const connect = () => {
      setWsStatus('connecting');
      socket = new WebSocket(`${proto}://${location.host}/ws/admin?token=${encodeURIComponent(token)}`);
      socket.onopen = () => {
        setWsStatus('connected');
        setSend((payload) => {
          if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
        });
      };
      socket.onmessage = (event) => {
        const payload = JSON.parse(event.data) as AdminEvent;
        if (payload.type === 'agent_status_changed') qc.invalidateQueries({ queryKey: ['devices'] });
        if (payload.type === 'chat_message') qc.invalidateQueries({ queryKey: ['messages', payload.session_id] });
        if (payload.type === 'session_status') {
          qc.invalidateQueries({ queryKey: ['session', payload.session_id] });
          if (['closed', 'agent_offline', 'heartbeat_timeout', 'rejected'].includes(payload.status)) {
            closeSession(payload.session_id, payload.status);
          }
        }
        if (payload.type === 'screen_frame') setFrame(payload);
        if (payload.type === 'control_ack') addLog(payload.session_id, `ack ${payload.kind} ${payload.key || payload.button || ''}`);
        if (payload.type === 'signal') {
          pushSignal(payload.session_id, payload.kind, payload.payload);
          addLog(payload.session_id, `signal ${payload.kind}`);
          if (payload.kind === 'session_closed') {
            const reason =
              typeof payload.payload === 'object' && payload.payload && 'reason' in payload.payload
                ? String((payload.payload as { reason?: unknown }).reason || 'closed')
                : 'closed';
            closeSession(payload.session_id, reason);
          }
        }
        if (payload.type === 'voice_status') {
          setVoice(payload.session_id, payload.status, payload.muted, payload.reason);
          addLog(payload.session_id, `voice ${payload.status}${payload.muted === null ? '' : ` muted=${payload.muted}`}`);
        }
      };
      socket.onclose = () => {
        setSend(null);
        setWsStatus('disconnected');
        if (!stopped) reconnectTimer = window.setTimeout(connect, 1500);
      };
      socket.onerror = () => socket?.close();
    };
    connect();
    return () => {
      stopped = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      setSend(null);
      setWsStatus('disconnected');
      socket?.close();
    };
  }, [addLog, closeSession, pushSignal, qc, setFrame, setSend, setVoice, setWsStatus, token]);
}

function LoginPage() {
  const [username, setUsername] = useState('admin');
  const [password, setPassword] = useState('admin123');
  const [error, setError] = useState('');
  const navigate = useNavigate();
  const setToken = useAuth((s) => s.setToken);
  const login = useMutation({
    mutationFn: () =>
      fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      }).then(async (res) => {
        if (!res.ok) throw new Error((await res.json().catch(() => null))?.error || '登录失败');
        return res.json() as Promise<{ token: string }>;
      }),
    onSuccess: (data) => {
      setToken(data.token);
      navigate('/devices');
    },
    onError: (err) => setError(err.message),
  });

  return (
    <div className="grid min-h-screen place-items-center bg-[#eef2eb] p-4 text-ink">
      <div className="w-full max-w-md border border-line bg-panel p-8 shadow-crisp">
        <div className="mb-8 flex items-center gap-4">
          <div className="grid h-12 w-12 place-items-center bg-ink text-white">
            <Cable />
          </div>
          <div>
            <h1 className="text-2xl font-semibold">Conductor</h1>
            <p className="text-sm text-ink/60">管理员登录</p>
          </div>
        </div>
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            setError('');
            login.mutate();
          }}
        >
          <label className="field">
            <span>账号</span>
            <input value={username} onChange={(e) => setUsername(e.target.value)} autoComplete="username" />
          </label>
          <label className="field">
            <span>密码</span>
            <input value={password} onChange={(e) => setPassword(e.target.value)} type="password" autoComplete="current-password" />
          </label>
          {error && <div className="border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">{error}</div>}
          <button className="primary w-full" disabled={login.isPending}>
            登录
          </button>
        </form>
      </div>
    </div>
  );
}

function DashboardPage() {
  const overview = useQuery({
    queryKey: ['overview'],
    queryFn: () => api<Overview>('/api/overview'),
    refetchInterval: 10000,
  });
  const data = overview.data;

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Overview</p>
          <h1>控制台概览</h1>
        </div>
        <button className="icon-text" onClick={() => overview.refetch()}>
          <RefreshCcw size={16} />
          刷新
        </button>
      </div>
      <div className="metric-grid">
        <Metric label="在线设备" value={`${data?.online_devices ?? 0}/${data?.total_devices ?? 0}`} />
        <Metric label="活跃会话" value={String(data?.active_sessions ?? 0)} />
        <Metric label="累计会话" value={String(data?.total_sessions ?? 0)} />
        <Metric label="审计事件" value={String(data?.audit_events ?? 0)} />
      </div>
      <div className="dashboard-grid">
        <section className="dash-panel">
          <div className="subsection-head">
            <h2>最近设备</h2>
            <Link className="icon-text" to="/devices">查看全部</Link>
          </div>
          <div className="mini-list">
            {(data?.recent_devices || []).map((device) => (
              <Link key={device.device_id} to={`/devices/${device.device_id}`} className="mini-row">
                <span><Status online={device.online === 1} /></span>
                <strong>{device.hostname || device.device_id}</strong>
                <small>{device.local_ip} / {formatTime(device.last_heartbeat)}</small>
              </Link>
            ))}
            {!overview.isLoading && (data?.recent_devices || []).length === 0 && <div className="empty compact">暂无设备</div>}
          </div>
        </section>
        <section className="dash-panel">
          <div className="subsection-head">
            <h2>最近会话</h2>
          </div>
          <div className="mini-list">
            {(data?.recent_sessions || []).map((session) => (
              <Link key={session.session_id} to={`/sessions/${session.session_id}`} className="mini-row">
                <span className={`status ${session.status === 'active' ? 'online' : ''}`}>{session.status}</span>
                <strong>{session.session_id}</strong>
                <small>{session.device_id} / {formatTime(session.created_at)}</small>
              </Link>
            ))}
            {!overview.isLoading && (data?.recent_sessions || []).length === 0 && <div className="empty compact">暂无会话</div>}
          </div>
        </section>
        <section className="dash-panel wide">
          <div className="subsection-head">
            <h2>最近审计</h2>
            <Link className="icon-text" to="/audit">查看审计</Link>
          </div>
          <div className="mini-list">
            {(data?.recent_audit_logs || []).map((log) => (
              <div key={log.id} className="mini-row">
                <span><code className="inline-code">{log.action}</code></span>
                <strong>{log.actor} / {log.target}</strong>
                <small>{log.detail} / {formatTime(log.created_at)}</small>
              </div>
            ))}
            {!overview.isLoading && (data?.recent_audit_logs || []).length === 0 && <div className="empty compact">暂无审计</div>}
          </div>
        </section>
      </div>
      {overview.error && <p className="error-line">{overview.error.message}</p>}
    </section>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function DevicesPage() {
  const [query, setQuery] = useState('');
  const [onlineOnly, setOnlineOnly] = useState(false);
  const devices = useQuery({ queryKey: ['devices'], queryFn: () => api<Device[]>('/api/devices'), refetchInterval: 15000 });
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return (devices.data || []).filter((d) => {
      const match = [d.hostname, d.os, d.username, d.local_ip].join(' ').toLowerCase().includes(needle);
      return match && (!onlineOnly || d.online === 1);
    });
  }, [devices.data, onlineOnly, query]);

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Devices</p>
          <h1>终端资产</h1>
        </div>
        <button className="icon-text" onClick={() => devices.refetch()}>
          <RefreshCcw size={16} />
          刷新
        </button>
      </div>
      <div className="toolbar">
        <div className="search">
          <Search size={16} />
          <input placeholder="搜索主机、用户、IP" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
        <label className="toggle">
          <input type="checkbox" checked={onlineOnly} onChange={(e) => setOnlineOnly(e.target.checked)} />
          仅在线
        </label>
      </div>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>状态</th>
              <th>主机</th>
              <th>系统</th>
              <th>用户</th>
              <th>IP</th>
              <th>版本</th>
              <th>最近心跳</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((device) => (
              <tr key={device.device_id} onClick={() => (location.href = `/devices/${device.device_id}`)}>
                <td><Status online={device.online === 1} /></td>
                <td className="font-medium">{device.hostname || '-'}</td>
                <td>{device.os} / {device.arch}</td>
                <td>{device.username || '-'}</td>
                <td>{device.local_ip || '-'}</td>
                <td>{device.agent_version}</td>
                <td>{formatTime(device.last_heartbeat)}</td>
              </tr>
            ))}
            {!devices.isLoading && filtered.length === 0 && (
              <tr><td colSpan={7} className="empty">暂无设备</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function DeviceDetailPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const device = useQuery({ queryKey: ['device', id], queryFn: () => api<Device>(`/api/devices/${id}`) });
  const sessions = useQuery({
    queryKey: ['device-sessions', id],
    queryFn: () => api<Session[]>(`/api/sessions?device_id=${encodeURIComponent(id)}&limit=8`),
    enabled: Boolean(id),
    refetchInterval: 5000,
  });
  const createSession = useMutation({
    mutationFn: () => api<Session>('/api/sessions', { method: 'POST', body: JSON.stringify({ device_id: id }) }),
    onSuccess: (s) => navigate(`/sessions/${s.session_id}`),
  });
  const createVoiceSession = useMutation({
    mutationFn: () => api<Session>('/api/sessions', { method: 'POST', body: JSON.stringify({ device_id: id }) }),
    onSuccess: (s) => navigate(`/sessions/${s.session_id}?voice=1`),
  });
  const openChat = () => {
    const existing = (sessions.data || []).find((session) => ['pending', 'active'].includes(session.status));
    if (existing) {
      navigate(`/sessions/${existing.session_id}`);
      return;
    }
    createSession.mutate();
  };
  const openVoice = () => {
    const existing = (sessions.data || []).find((session) => ['pending', 'active'].includes(session.status));
    if (existing) {
      navigate(`/sessions/${existing.session_id}?voice=1`);
      return;
    }
    createVoiceSession.mutate();
  };

  if (device.isLoading) return <section className="page">加载中</section>;
  if (!device.data) return <section className="page">设备不存在</section>;
  const d = device.data;
  const online = d.online === 1;

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Device</p>
          <h1>{d.hostname}</h1>
        </div>
        <Status online={online} />
      </div>
      <div className="info-grid">
        <Info label="设备 ID" value={d.device_id} />
        <Info label="系统" value={`${d.os} / ${d.arch}`} />
        <Info label="用户" value={d.username} />
        <Info label="IP" value={d.local_ip} />
        <Info label="Agent" value={d.agent_version} />
        <Info label="最近心跳" value={formatTime(d.last_heartbeat)} />
      </div>
      <div className="actions-band">
        <button className="primary" disabled={!online || createSession.isPending} onClick={() => createSession.mutate()}>
          <MonitorDot size={18} />
          远程控制
        </button>
        <Link className={`button ${online ? '' : 'disabled'}`} to={`/devices/${id}/files`}>
          <FileDown size={18} />
          文件管理
        </Link>
        <button className="button" disabled={!online || createSession.isPending} onClick={openChat}>
          <MessageSquare size={18} />
          文字沟通
        </button>
        <button className="button" disabled={!online || createVoiceSession.isPending} onClick={openVoice}>
          <Volume2 size={18} />
          语音沟通
        </button>
      </div>
      {(createSession.error || createVoiceSession.error) && <p className="error-line">{(createSession.error || createVoiceSession.error)?.message}</p>}
      <section className="subsection">
        <div className="subsection-head">
          <h2>最近会话</h2>
          <button className="icon-text" onClick={() => sessions.refetch()}><RefreshCcw size={16} />刷新</button>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>状态</th>
                <th>会话 ID</th>
                <th>创建时间</th>
                <th>关闭时间</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {(sessions.data || []).map((s) => (
                <tr key={s.session_id}>
                  <td><span className={`status ${s.status === 'active' ? 'online' : ''}`}>{s.status}</span></td>
                  <td className="font-mono text-xs">{s.session_id}</td>
                  <td>{formatTime(s.created_at)}</td>
                  <td>{formatTime(s.closed_at)}</td>
                  <td>
                    {['pending', 'active'].includes(s.status) && (
                      <Link className="icon-text" to={`/sessions/${s.session_id}`}>进入</Link>
                    )}
                  </td>
                </tr>
              ))}
              {!sessions.isLoading && (sessions.data || []).length === 0 && (
                <tr><td colSpan={5} className="empty">暂无会话</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}

function AuditPage() {
  const [query, setQuery] = useState('');
  const logs = useQuery({
    queryKey: ['audit-logs', query],
    queryFn: () => api<AuditLog[]>(`/api/audit-logs?limit=200&q=${encodeURIComponent(query)}`),
    refetchInterval: 10000,
  });

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Audit</p>
          <h1>操作审计</h1>
        </div>
        <button className="icon-text" onClick={() => logs.refetch()}>
          <RefreshCcw size={16} />
          刷新
        </button>
      </div>
      <div className="toolbar">
        <div className="search">
          <Search size={16} />
          <input placeholder="搜索账号、动作、目标或详情" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
      </div>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>时间</th>
              <th>账号</th>
              <th>动作</th>
              <th>目标</th>
              <th>详情</th>
            </tr>
          </thead>
          <tbody>
            {(logs.data || []).map((log) => (
              <tr key={log.id}>
                <td>{formatTime(log.created_at)}</td>
                <td className="font-medium">{log.actor}</td>
                <td><code className="inline-code">{log.action}</code></td>
                <td className="break-all">{log.target}</td>
                <td className="break-all">{log.detail}</td>
              </tr>
            ))}
            {!logs.isLoading && (logs.data || []).length === 0 && (
              <tr><td colSpan={5} className="empty">暂无审计记录</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {logs.error && <p className="error-line">{logs.error.message}</p>}
    </section>
  );
}

function RemotePage() {
  const { sessionId = '' } = useParams();
  const location = useLocation();
  const navigate = useNavigate();
  const session = useQuery({ queryKey: ['session', sessionId], queryFn: () => api<Session>(`/api/sessions/${sessionId}`), refetchInterval: 5000 });
  const device = useQuery({
    queryKey: ['session-device', session.data?.device_id],
    queryFn: () => api<Device>(`/api/devices/${session.data?.device_id}`),
    enabled: Boolean(session.data?.device_id),
    refetchInterval: 10000,
  });
  const close = useMutation({
    mutationFn: () => api<Session>(`/api/sessions/${sessionId}/close`, { method: 'POST' }),
    onSuccess: (s) => navigate(`/devices/${s.device_id}`),
  });
  const [events, setEvents] = useState<string[]>([]);
  const lastMove = useRef(0);
  const frame = useLive((s) => s.frames[sessionId]);
  const liveLogs = useLive((s) => s.logs[sessionId] || []);
  const signals = useLive((s) => s.signals[sessionId] || []);
  const voice = useLive((s) => s.voice[sessionId]);
  const closeReason = useLive((s) => s.closedSessions[sessionId]);
  const wsStatus = useLive((s) => s.wsStatus);
  const send = useLive((s) => s.send);
  const sessionStatus = session.data?.status || 'connecting';
  const interactiveEnabled = sessionStatus === 'active' && !closeReason;
  const awaitingApproval = sessionStatus === 'pending' && !closeReason;
  const rejected = sessionStatus === 'rejected';
  const [localVoiceStream, setLocalVoiceStream] = useState<MediaStream | null>(null);
  const rtcVoiceStream = voice
    && ['accepted', 'muted'].includes(voice.status)
    && !voice.muted
    ? localVoiceStream
    : null;
  const addRtcEvent = useCallback((line: string) => {
    setEvents((current) => [line, ...current].slice(0, 8));
  }, []);
  const rtc = useSessionRtc({
    sessionId,
    enabled: interactiveEnabled,
    send,
    signals,
    localAudioStream: rtcVoiceStream,
    addEvent: addRtcEvent,
  });
  const remoteVideoRef = useRef<HTMLVideoElement | null>(null);
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);
  const hasRtcVideo = Boolean(rtc.remoteStream?.getVideoTracks().length);
  const hasRtcAudio = Boolean(rtc.remoteStream?.getAudioTracks().length);
  const sendControl = (event: Omit<ControlEventPayload, 'type' | 'session_id' | 'created_at'>) => {
    if (!interactiveEnabled) return;
    const payload: ControlEventPayload = {
      type: 'control_event',
      session_id: sessionId,
      created_at: new Date().toISOString(),
      ...event,
    };
    const viaRtc = rtc.sendControl(payload);
    if (!viaRtc) send?.(payload);
    setEvents((v) => [`sent ${event.kind} ${event.key || event.button || ''} via ${viaRtc ? 'rtc' : 'ws'}`, ...v].slice(0, 8));
  };
  useEffect(() => {
    const closeOnPageHide = () => {
      const token = useAuth.getState().token;
      if (!token || !sessionId) return;
      fetch(`/api/sessions/${sessionId}/close`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        keepalive: true,
      }).catch(() => undefined);
    };
    window.addEventListener('pagehide', closeOnPageHide);
    return () => window.removeEventListener('pagehide', closeOnPageHide);
  }, [sessionId]);
  useEffect(() => {
    if (remoteVideoRef.current) {
      remoteVideoRef.current.srcObject = hasRtcVideo ? rtc.remoteStream : null;
    }
    if (remoteAudioRef.current) {
      remoteAudioRef.current.srcObject = hasRtcAudio ? rtc.remoteStream : null;
    }
  }, [hasRtcAudio, hasRtcVideo, rtc.remoteStream]);

  return (
    <section className="remote-page">
      <div className="remote-top">
        <div>
          <p className="eyebrow">Remote Session</p>
          <h1>{sessionStatus}</h1>
        </div>
        <button className="danger" onClick={() => close.mutate()}>结束会话</button>
      </div>
      {awaitingApproval && (
        <div className="session-banner">
          <span>等待被控端确认远控请求，当前不会发送控制或语音指令。</span>
        </div>
      )}
      {rejected && !closeReason && (
        <div className="session-banner">
          <span>被控端已拒绝本次远控请求。</span>
          <button className="icon-text" onClick={() => session.data?.device_id && navigate(`/devices/${session.data.device_id}`)}>返回设备</button>
        </div>
      )}
      {closeReason && (
        <div className="session-banner">
          <span>会话已关闭：{closeReason}</span>
          <button className="icon-text" onClick={() => session.data?.device_id && navigate(`/devices/${session.data.device_id}`)}>返回设备</button>
        </div>
      )}
      <div className="remote-grid">
        <div
          className="screen"
          tabIndex={0}
          onMouseMove={(e) => {
            if (!interactiveEnabled) return;
            const now = performance.now();
            if (now - lastMove.current < 180) return;
            lastMove.current = now;
            const video = remoteVideoRef.current;
            const [sourceWidth, sourceHeight] = video?.videoWidth && video.videoHeight
              ? [video.videoWidth, video.videoHeight]
              : [frame?.width || 16, frame?.height || 9];
            const position = normalizedMediaPosition(
              e.clientX,
              e.clientY,
              e.currentTarget.getBoundingClientRect(),
              sourceWidth,
              sourceHeight,
            );
            sendControl({
              kind: 'mouse_move',
              x: position.x,
              y: position.y,
            });
          }}
          onClick={(e) => {
            if (!interactiveEnabled) return;
            const video = remoteVideoRef.current;
            const [sourceWidth, sourceHeight] = video?.videoWidth && video.videoHeight
              ? [video.videoWidth, video.videoHeight]
              : [frame?.width || 16, frame?.height || 9];
            const position = normalizedMediaPosition(
              e.clientX,
              e.clientY,
              e.currentTarget.getBoundingClientRect(),
              sourceWidth,
              sourceHeight,
            );
            sendControl({
              kind: 'mouse_click',
              x: position.x,
              y: position.y,
              button: 'left',
            });
          }}
          onWheel={(e) => {
            if (!interactiveEnabled) return;
            sendControl({
              kind: 'mouse_wheel',
              delta_x: e.deltaX,
              delta_y: e.deltaY,
            });
          }}
          onKeyDown={(e) => {
            e.preventDefault();
            if (interactiveEnabled) sendControl({ kind: 'key_down', key: e.key });
          }}
        >
          {hasRtcVideo ? (
            <video
              ref={remoteVideoRef}
              className="screen-frame"
              autoPlay
              playsInline
              muted
            />
          ) : frame ? (
            <img className="screen-frame" src={frame.image_data_url} alt="Agent screen frame" />
          ) : (
            <div className="screen-inner">
              <MonitorDot size={48} />
              <strong>等待 Agent 画面</strong>
              <span>{awaitingApproval ? '被控端确认后才会进入可控状态。' : '点击画面区域后可发送鼠标与键盘事件。'}</span>
            </div>
          )}
          {!interactiveEnabled && (
            <div className="screen-overlay">
              <span>{awaitingApproval ? '等待确认' : closeReason || rejected ? '会话不可用' : '连接中'}</span>
            </div>
          )}
          <audio ref={remoteAudioRef} autoPlay />
        </div>
        <aside className="side-panel">
          <SessionSummary
            sessionId={sessionId}
            sessionStatus={sessionStatus}
            device={device.data}
            frameTime={frame?.captured_at || null}
            voiceStatus={voice?.status || 'idle'}
            wsStatus={wsStatus}
            rtcStatus={rtc.status}
            rtcDetail={rtc.detail}
            mediaStatus={hasRtcVideo ? 'remote_video' : hasRtcAudio ? 'remote_audio' : frame ? 'fallback_frame' : 'waiting_media'}
          />
          <SessionTools deviceId={session.data?.device_id || ''} />
          <ChatPanel
            sessionId={sessionId}
            sessionStatus={sessionStatus}
            closeReason={closeReason}
          />
          <VoicePanel
            sessionId={sessionId}
            voice={voice}
            send={send}
            autoRequest={new URLSearchParams(location.search).get('voice') === '1'}
            disabled={!interactiveEnabled}
            onLocalStreamChange={setLocalVoiceStream}
          />
          <div className="event-log">
            <h3>
              输入与信令
              {rtc.canRetry && (
                <button className="icon-text" onClick={rtc.retry} title="重新建立 WebRTC 连接">
                  <RefreshCcw size={14} />
                  重试连接
                </button>
              )}
            </h3>
            {frame && <code>frame {frame.width}x{frame.height} {formatTime(frame.captured_at)}</code>}
            <code>rtc {rtc.status}{rtc.detail ? ` / ${rtc.detail}` : ''}</code>
            {liveLogs.map((event, i) => <code key={`live-${event}-${i}`}>{event}</code>)}
            {events.map((event, i) => <code key={`${event}-${i}`}>{event}</code>)}
          </div>
        </aside>
      </div>
    </section>
  );
}

function normalizedMediaPosition(
  clientX: number,
  clientY: number,
  bounds: Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>,
  sourceWidth: number,
  sourceHeight: number,
) {
  const containerWidth = Math.max(bounds.width, 1);
  const containerHeight = Math.max(bounds.height, 1);
  const sourceAspect = Math.max(sourceWidth, 1) / Math.max(sourceHeight, 1);
  const containerAspect = containerWidth / containerHeight;
  const mediaWidth = containerAspect > sourceAspect
    ? containerHeight * sourceAspect
    : containerWidth;
  const mediaHeight = containerAspect > sourceAspect
    ? containerHeight
    : containerWidth / sourceAspect;
  const mediaLeft = bounds.left + (containerWidth - mediaWidth) / 2;
  const mediaTop = bounds.top + (containerHeight - mediaHeight) / 2;
  const x = Math.min(1, Math.max(0, (clientX - mediaLeft) / mediaWidth));
  const y = Math.min(1, Math.max(0, (clientY - mediaTop) / mediaHeight));
  return {
    x: Number(x.toFixed(4)),
    y: Number(y.toFixed(4)),
  };
}

function SessionSummary({
  sessionId,
  sessionStatus,
  device,
  frameTime,
  voiceStatus,
  wsStatus,
  rtcStatus,
  rtcDetail,
  mediaStatus,
}: {
  sessionId: string;
  sessionStatus: string;
  device?: Device;
  frameTime: string | null;
  voiceStatus: string;
  wsStatus: string;
  rtcStatus: string;
  rtcDetail?: string;
  mediaStatus: string;
}) {
  return (
    <div className="tool-panel">
      <h3><Activity size={16} /> 会话状态</h3>
      <div className="summary-grid">
        <Info label="会话" value={sessionId} />
        <Info label="状态" value={sessionStatus} />
        <Info label="终端" value={device?.hostname || device?.device_id || '-'} />
        <Info label="网络" value={wsStatus} />
        <Info label="信令" value={rtcDetail ? `${rtcStatus} / ${rtcDetail}` : rtcStatus} />
        <Info label="媒体" value={mediaStatus} />
        <Info label="语音" value={voiceStatus} />
        <Info label="最近帧" value={formatTime(frameTime)} />
      </div>
    </div>
  );
}

function useSessionRtc({
  sessionId,
  enabled,
  send,
  signals,
  localAudioStream,
  addEvent,
}: {
  sessionId: string;
  enabled: boolean;
  send: ((payload: unknown) => void) | null;
  signals: { kind: string; payload: unknown; receivedAt: string }[];
  localAudioStream: MediaStream | null;
  addEvent: (line: string) => void;
}) {
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const controlChannelRef = useRef<RTCDataChannel | null>(null);
  const audioSenderRef = useRef<RTCRtpSender | null>(null);
  const processedSignalCount = useRef(0);
  const answerTimer = useRef<number | null>(null);
  const [status, setStatus] = useState('idle');
  const [detail, setDetail] = useState('');
  const [remoteStream, setRemoteStream] = useState<MediaStream | null>(null);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (!enabled || !send || !sessionId) {
      if (answerTimer.current) {
        window.clearTimeout(answerTimer.current);
        answerTimer.current = null;
      }
      peerRef.current?.close();
      peerRef.current = null;
      controlChannelRef.current = null;
      audioSenderRef.current = null;
      processedSignalCount.current = 0;
      setRemoteStream(null);
      setStatus(enabled ? 'ready' : 'idle');
      setDetail('');
      return;
    }
    if (peerRef.current) return;
    const peer = new RTCPeerConnection();
    peerRef.current = peer;
    processedSignalCount.current = signals.length;
    setStatus('creating_offer');
    setDetail('initializing');
    addEvent('rtc init');

    const update = (next: string, nextDetail = '') => {
      setStatus(next);
      setDetail(nextDetail);
    };

    peer.addTransceiver('video', { direction: 'recvonly' });
    audioSenderRef.current = peer.addTransceiver('audio', { direction: 'sendrecv' }).sender;

    const controlChannel = peer.createDataChannel('control');
    controlChannelRef.current = controlChannel;
    controlChannel.onopen = () => addEvent('rtc control open');
    controlChannel.onclose = () => {
      addEvent('rtc control close');
      if (controlChannelRef.current === controlChannel) {
        controlChannelRef.current = null;
      }
    };
    controlChannel.onerror = () => addEvent('rtc control error');
    peer.onicecandidate = (event) => {
      if (!event.candidate) return;
      send({
        type: 'webrtc_ice_candidate',
        session_id: sessionId,
        candidate: event.candidate.toJSON(),
      });
      addEvent('rtc local ice');
    };
    peer.onconnectionstatechange = () => {
      update('peer', peer.connectionState);
      addEvent(`rtc connection ${peer.connectionState}`);
    };
    peer.oniceconnectionstatechange = () => {
      update('ice', peer.iceConnectionState);
      addEvent(`rtc ice ${peer.iceConnectionState}`);
    };
    peer.onsignalingstatechange = () => {
      update('signaling', peer.signalingState);
    };
    peer.ontrack = (event) => {
      addEvent(`rtc track ${event.track.kind}`);
      if (event.streams[0]) {
        setRemoteStream(event.streams[0]);
        update('media', event.track.kind);
        return;
      }
      setRemoteStream((current) => {
        const stream = current ? new MediaStream(current.getTracks()) : new MediaStream();
        if (!stream.getTracks().find((track) => track.id === event.track.id)) {
          stream.addTrack(event.track);
        }
        return stream;
      });
      update('media', event.track.kind);
    };

    void (async () => {
      try {
        const offer = await peer.createOffer();
        await peer.setLocalDescription(offer);
        send({
          type: 'webrtc_offer',
          session_id: sessionId,
          sdp: offer.sdp || '',
        });
        update('offer_sent', 'waiting_answer');
        addEvent('rtc offer sent');
        answerTimer.current = window.setTimeout(() => {
          update('offer_timeout', 'no answer');
          addEvent('rtc answer timeout');
        }, 8000);
      } catch (error) {
        const message = error instanceof Error ? error.message : 'offer failed';
        update('offer_failed', message);
        addEvent(`rtc error ${message}`);
      }
    })();

    return () => {
      if (answerTimer.current) {
        window.clearTimeout(answerTimer.current);
        answerTimer.current = null;
      }
      peer.close();
      if (peerRef.current === peer) peerRef.current = null;
      if (controlChannelRef.current === controlChannel) controlChannelRef.current = null;
      audioSenderRef.current = null;
      processedSignalCount.current = 0;
      setRemoteStream(null);
    };
  }, [addEvent, attempt, enabled, send, sessionId]);

  useEffect(() => {
    const sender = audioSenderRef.current;
    if (!sender) return;
    const track = localAudioStream?.getAudioTracks()[0] || null;
    void sender.replaceTrack(track).then(
      () => addEvent(track ? 'rtc microphone attached' : 'rtc microphone detached'),
      (error) => addEvent(`rtc microphone error ${error instanceof Error ? error.message : 'replace track failed'}`),
    );
  }, [addEvent, attempt, localAudioStream]);

  useEffect(() => {
    const peer = peerRef.current;
    if (!peer) return;
    const newSignals = signals.slice(processedSignalCount.current);
    if (newSignals.length === 0) return;
    processedSignalCount.current = signals.length;
    for (const signal of newSignals) {
      void (async () => {
        try {
          if (signal.kind === 'answer') {
            const payload = signal.payload as { sdp?: unknown };
            if (typeof payload?.sdp !== 'string' || !payload.sdp) {
              throw new Error('missing answer sdp');
            }
            await peer.setRemoteDescription({ type: 'answer', sdp: payload.sdp });
            if (answerTimer.current) {
              window.clearTimeout(answerTimer.current);
              answerTimer.current = null;
            }
            setStatus('answer_applied');
            setDetail('remote description set');
            addEvent('rtc answer applied');
            return;
          }
          if (signal.kind === 'ice_candidate') {
            await peer.addIceCandidate(signal.payload as RTCIceCandidateInit);
            addEvent('rtc remote ice');
            return;
          }
          if (signal.kind === 'offer') {
            setStatus('unexpected_offer');
            setDetail('agent offer not supported yet');
            addEvent('rtc unexpected offer');
          }
        } catch (error) {
          const message = error instanceof Error ? error.message : `signal ${signal.kind} failed`;
          setStatus('signal_error');
          setDetail(`${signal.kind}: ${message}`);
          addEvent(`rtc ${signal.kind} error`);
        }
      })();
    }
  }, [addEvent, signals]);

  const sendControl = (payload: ControlEventPayload) => {
    const channel = controlChannelRef.current;
    if (!channel || channel.readyState !== 'open') return false;
    channel.send(JSON.stringify(payload));
    return true;
  };

  const canRetry = enabled && (
    status === 'offer_timeout'
    || status === 'offer_failed'
    || status === 'signal_error'
    || ((status === 'peer' || status === 'ice') && ['failed', 'disconnected', 'closed'].includes(detail))
  );
  const retry = () => {
    if (!canRetry) return;
    setStatus('retrying');
    setDetail('restarting connection');
    setAttempt((current) => current + 1);
  };

  return { status, detail, sendControl, remoteStream, canRetry, retry };
}

function SessionTools({ deviceId }: { deviceId: string }) {
  if (!deviceId) return null;
  return (
    <div className="tool-panel">
      <h3><FolderOpen size={16} /> 会话快捷入口</h3>
      <div className="tool-actions">
        <Link className="icon-text" to={`/devices/${deviceId}`}>设备详情</Link>
        <Link className="icon-text" to={`/devices/${deviceId}/files`}>文件管理</Link>
      </div>
    </div>
  );
}

function VoicePanel({
  sessionId,
  voice,
  send,
  autoRequest,
  disabled,
  onLocalStreamChange,
}: {
  sessionId: string;
  voice?: { status: string; muted: boolean; reason?: string | null };
  send: ((payload: unknown) => void) | null;
  autoRequest?: boolean;
  disabled?: boolean;
  onLocalStreamChange: (stream: MediaStream | null) => void;
}) {
  const status = voice?.status || 'idle';
  const muted = voice?.muted || false;
  const [localError, setLocalError] = useState('');
  const streamRef = useRef<MediaStream | null>(null);
  const autoRequested = useRef(false);
  const sendVoice = (payload: unknown) => send?.(payload);
  const requestVoice = async () => {
    setLocalError('');
    try {
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error('浏览器不支持麦克风权限检测');
      }
      streamRef.current = await navigator.mediaDevices.getUserMedia({ audio: true });
      onLocalStreamChange(streamRef.current);
      sendVoice({ type: 'voice_request', session_id: sessionId });
    } catch (err) {
      setLocalError(err instanceof Error ? err.message : '麦克风不可用');
    }
  };
  const hangupVoice = () => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    onLocalStreamChange(null);
    sendVoice({ type: 'voice_hangup', session_id: sessionId });
  };
  useEffect(() => () => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    onLocalStreamChange(null);
  }, [onLocalStreamChange]);
  useEffect(() => {
    if (!['rejected', 'hangup'].includes(status)) return;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    onLocalStreamChange(null);
  }, [onLocalStreamChange, status]);
  useEffect(() => {
    if (!autoRequest || autoRequested.current || !send || disabled || status !== 'idle') return;
    autoRequested.current = true;
    void requestVoice();
  }, [autoRequest, disabled, send, status]);
  return (
    <div className="voice-panel">
      <div>
        <h3><Volume2 size={16} /> 语音沟通</h3>
        <p>{disabled ? '等待远控会话进入 active 后再发起语音。' : localError || `${status}${voice?.reason ? ` / ${voice.reason}` : ''}`}</p>
      </div>
      <div className="voice-actions">
        <button
          className="icon-only"
          title="开启语音"
          onClick={requestVoice}
          disabled={disabled || !send || ['requesting', 'accepted'].includes(status)}
        >
          <Mic size={16} />
        </button>
        <button
          className="icon-only"
          title={muted ? '取消静音' : '静音'}
          onClick={() => sendVoice({ type: 'voice_mute', session_id: sessionId, muted: !muted })}
          disabled={disabled || !send || !['requesting', 'accepted', 'muted'].includes(status)}
        >
          {muted ? <MicOff size={16} /> : <Volume2 size={16} />}
        </button>
        <button
          className="icon-only danger-text"
          title="挂断"
          onClick={hangupVoice}
          disabled={disabled || !send || status === 'idle' || status === 'hangup'}
        >
          <PhoneOff size={16} />
        </button>
      </div>
    </div>
  );
}

function ChatPanel({
  sessionId,
  sessionStatus,
  closeReason,
}: {
  sessionId: string;
  sessionStatus: string;
  closeReason?: string;
}) {
  const [text, setText] = useState('');
  const endRef = useRef<HTMLDivElement>(null);
  const qc = useQueryClient();
  const chatLocked = Boolean(closeReason) || !['pending', 'active'].includes(sessionStatus);
  const messages = useQuery({
    queryKey: ['messages', sessionId],
    queryFn: () => api<ChatMessage[]>(`/api/sessions/${sessionId}/messages`),
    enabled: Boolean(sessionId),
  });
  const send = useMutation({
    mutationFn: () => api<ChatMessage>(`/api/sessions/${sessionId}/messages`, { method: 'POST', body: JSON.stringify({ text }) }),
    onSuccess: () => {
      setText('');
      qc.invalidateQueries({ queryKey: ['messages', sessionId] });
    },
  });
  useEffect(() => endRef.current?.scrollIntoView({ block: 'end' }), [messages.data]);
  return (
    <div className="chat">
      <h3><MessageSquare size={16} /> 文字沟通</h3>
      <div className="chat-list">
        {(messages.data || []).map((m) => (
          <div className={`bubble ${m.sender === 'admin' ? 'self' : ''}`} key={m.message_id}>
            <span>{m.sender}</span>
            <p>{m.text}</p>
          </div>
        ))}
        <div ref={endRef} />
      </div>
      {chatLocked && (
        <div className="chat-note">
          会话已结束，不能继续发送消息。
        </div>
      )}
      <form
        className="chat-send"
        onSubmit={(e) => {
          e.preventDefault();
          if (!chatLocked && text.trim()) send.mutate();
        }}
      >
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="输入消息" disabled={chatLocked || send.isPending} />
        <button title="发送" disabled={chatLocked || send.isPending}><Send size={16} /></button>
      </form>
    </div>
  );
}

function FilesPage() {
  const { id = '' } = useParams();
  const [path, setPath] = useState('.');
  const [mkdirName, setMkdirName] = useState('');
  const qc = useQueryClient();
  const device = useQuery({
    queryKey: ['files-device', id],
    queryFn: () => api<Device>(`/api/devices/${id}`),
    enabled: Boolean(id),
  });
  const files = useQuery({
    queryKey: ['files', id, path],
    queryFn: () => api<{ ok: boolean; error?: string; entries?: FileEntry[] }>(`/api/devices/${id}/files?path=${encodeURIComponent(path)}`),
  });
  const refresh = () => qc.invalidateQueries({ queryKey: ['files', id, path] });
  const mkdir = useMutation({
    mutationFn: () => api(`/api/devices/${id}/files/mkdir`, { method: 'POST', body: JSON.stringify({ path, name: mkdirName }) }),
    onSuccess: () => { setMkdirName(''); refresh(); },
  });
  const del = useMutation({
    mutationFn: (target: string) => api(`/api/devices/${id}/files?path=${encodeURIComponent(target)}`, { method: 'DELETE' }),
    onSuccess: refresh,
  });
  const upload = useMutation({
    mutationFn: (file: File) => {
      const existing = (files.data?.entries || []).find((entry) => !entry.is_dir && entry.name === file.name);
      if (existing && !confirm(`目录中已存在 ${file.name}，是否覆盖?`)) {
        throw new Error('已取消上传');
      }
      const data = new FormData();
      data.set('path', path);
      data.set('file', file);
      return api(`/api/devices/${id}/files/upload`, { method: 'POST', body: data });
    },
    onSuccess: refresh,
  });
  const download = useMutation({
    mutationFn: async (target: string) => {
      const token = useAuth.getState().token;
      const res = await fetch(`/api/devices/${id}/files/download?path=${encodeURIComponent(target)}`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(body.error || res.statusText);
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = target.split('/').pop() || 'download.bin';
      a.click();
      URL.revokeObjectURL(url);
    },
  });
  const crumbs = path === '.'
    ? ['.']
    : path.split('/').filter(Boolean);
  const goParent = () => {
    if (path === '.' || !path) return;
    const parts = path.split('/').filter(Boolean);
    setPath(parts.length <= 1 ? '.' : parts.slice(0, -1).join('/'));
  };
  const busyLabel = upload.isPending
    ? '上传中'
    : download.isPending
      ? '下载中'
      : del.isPending
        ? '删除中'
        : mkdir.isPending
          ? '创建目录中'
          : '';

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Files</p>
          <h1>远端文件</h1>
          <p className="page-meta">{device.data?.hostname || id} / {path}</p>
        </div>
        <button className="icon-text" onClick={refresh}><RefreshCcw size={16} />刷新</button>
      </div>
      <div className="toolbar">
        <button className="icon-text" onClick={goParent} disabled={path === '.' || files.isFetching}>
          上级
        </button>
        <div className="crumbs">
          {crumbs.map((part, index) => {
            const target = index === 0 && part === '.'
              ? '.'
              : crumbs.slice(0, index + 1).filter((item) => item !== '.').join('/') || '.';
            return (
              <button key={`${target}-${index}`} className="crumb" onClick={() => setPath(target)}>
                {index > 0 && <ChevronRight size={14} />}
                <span>{part}</span>
              </button>
            );
          })}
        </div>
        <input className="path-input" value={path} onChange={(e) => setPath(e.target.value || '.')} />
        <input className="path-input" placeholder="新目录名称" value={mkdirName} onChange={(e) => setMkdirName(e.target.value)} />
        <button className="icon-text" onClick={() => mkdir.mutate()} disabled={!mkdirName.trim() || Boolean(busyLabel)}><FolderPlus size={16} />新建</button>
        <label className="icon-text file-pick">
          <Upload size={16} />上传
          <input type="file" onChange={(e) => e.target.files?.[0] && upload.mutate(e.target.files[0])} disabled={Boolean(busyLabel)} />
        </label>
        {busyLabel && <span className="busy-pill">{busyLabel}</span>}
      </div>
      <div className="table-wrap">
        <table>
          <thead><tr><th>名称</th><th>大小</th><th>修改时间</th><th>操作</th></tr></thead>
          <tbody>
            {(files.data?.entries || []).map((f) => (
              <tr key={f.path}>
                <td>
                  <button className="linkish" onClick={() => f.is_dir && setPath(f.path)}>{f.is_dir ? '目录' : '文件'} / {f.name}</button>
                </td>
                <td>{f.is_dir ? '-' : formatSize(f.size)}</td>
                <td>{formatTime(f.modified)}</td>
                <td className="row-actions">
                  {!f.is_dir && <button className="icon-only" onClick={() => download.mutate(f.path)} title="下载"><FileDown size={16} /></button>}
                  <button className="icon-only danger-text" onClick={() => confirm(`删除 ${f.name}?`) && del.mutate(f.path)} title="删除"><Trash2 size={16} /></button>
                </td>
              </tr>
            ))}
            {!files.isLoading && (files.data?.entries || []).length === 0 && <tr><td colSpan={4} className="empty">目录为空</td></tr>}
          </tbody>
        </table>
      </div>
      {(files.error || mkdir.error || del.error || upload.error || download.error) && <p className="error-line">{(files.error || mkdir.error || del.error || upload.error || download.error)?.message}</p>}
    </section>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  return <div className="info"><span>{label}</span><strong>{value || '-'}</strong></div>;
}

function Status({ online }: { online: boolean }) {
  return <span className={`status ${online ? 'online' : ''}`}>{online ? '在线' : '离线'}</span>;
}

function formatTime(value: string | null) {
  if (!value) return '-';
  return new Intl.DateTimeFormat('zh-CN', { dateStyle: 'short', timeStyle: 'medium' }).format(new Date(value));
}

function formatSize(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

function Root() {
  return (
    <React.StrictMode>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/*" element={<AppShell />} />
          </Routes>
        </BrowserRouter>
      </QueryClientProvider>
    </React.StrictMode>
  );
}

createRoot(document.getElementById('root')!).render(<Root />);
