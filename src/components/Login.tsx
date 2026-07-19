import { FormEvent, useState } from 'react';
import { LogIn } from 'lucide-react';
import { login } from '../lib/session';
import { SessionUser } from '../types';

export default function Login({ onLoggedIn }: { onLoggedIn: (u: SessionUser) => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const user = await login(email.trim(), password);
      if (!user) {
        setError('Inloggen gelukt, maar geen profiel gevonden.');
        return;
      }
      onLoggedIn(user);
    } catch (err: any) {
      setError(err?.message ?? 'Inloggen mislukt.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-full flex items-center justify-center p-4">
      <form onSubmit={submit} className="w-full max-w-sm bg-white rounded-xl shadow p-6 space-y-4">
        <div className="flex items-center gap-2 text-green-700">
          <LogIn size={22} />
          <h1 className="text-lg font-semibold">Greenspeed Planner</h1>
        </div>
        <p className="text-sm text-slate-500">Log in met je Greenspeed-account.</p>
        <div>
          <label className="block text-sm font-medium mb-1">E-mail</label>
          <input
            type="email" value={email} onChange={(e) => setEmail(e.target.value)}
            required autoComplete="username"
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Wachtwoord</label>
          <input
            type="password" value={password} onChange={(e) => setPassword(e.target.value)}
            required autoComplete="current-password"
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm"
          />
        </div>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button
          type="submit" disabled={busy}
          className="w-full bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg py-2 text-sm font-medium"
        >
          {busy ? 'Bezig…' : 'Inloggen'}
        </button>
      </form>
    </div>
  );
}
