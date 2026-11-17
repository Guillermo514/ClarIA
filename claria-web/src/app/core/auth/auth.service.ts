import { Injectable, computed, inject, signal } from '@angular/core';
import { AuthError, Session } from '@supabase/supabase-js';

import { Profile, RoleName, SignUpData } from '../models/domain.models';
import { PRIVACY_NOTICE_VERSION } from '../supabase/supabase.config';
import { SupabaseService } from '../supabase/supabase.service';

/** Mensajes de Supabase Auth traducidos para el estudiante. */
const AUTH_ERRORS: [RegExp, string][] = [
  [/invalid login credentials/i, 'El correo o la contraseña no son correctos.'],
  [/email not confirmed/i, 'Primero confirma tu correo con el enlace que te enviamos.'],
  [/already registered|already been registered/i, 'Ya existe una cuenta con ese correo.'],
  [/password should be at least/i, 'La contraseña debe tener al menos 8 caracteres.'],
  [/rate limit|too many/i, 'Hiciste demasiados intentos. Espera unos minutos.'],
  [/invalid email|unable to validate email/i, 'El correo no es válido.'],
  [
    /database error saving new user/i,
    'No pudimos crear la cuenta. Revisa tus datos e inténtalo de nuevo.',
  ],
];

function translate(error: AuthError): string {
  return AUTH_ERRORS.find(([pattern]) => pattern.test(error.message))?.[1] ?? error.message;
}

/** Sesión del usuario y su perfil en ClarIA. */
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly supabase = inject(SupabaseService).client;

  readonly session = signal<Session | null>(null);
  readonly profile = signal<Profile | null>(null);
  readonly isLoggedIn = computed(() => this.session() !== null);
  /** Docentes y administradores ven todos los niveles desbloqueados. */
  readonly isStaff = computed(() => ['admin', 'teacher'].includes(this.profile()?.role ?? ''));
  readonly roleLabel = computed(
    () =>
      ({ admin: 'Administrador', teacher: 'Docente', student: null })[
        this.profile()?.role ?? 'student'
      ],
  );

  readonly displayName = computed(() => this.profile()?.fullName ?? 'Estudiante');
  readonly initials = computed(() =>
    this.displayName()
      .split(/\s+/)
      .slice(0, 2)
      .map((word) => word.charAt(0).toUpperCase())
      .join(''),
  );

  /** Se resuelve cuando ya se sabe si hay sesión (lo esperan los guards). */
  readonly ready: Promise<void>;

  constructor() {
    this.ready = this.restoreSession();

    this.supabase.auth.onAuthStateChange((_event, session) => {
      this.session.set(session);
      // Supabase recomienda no llamar a la API dentro de este callback: se difiere.
      setTimeout(() => void this.loadProfile());
    });
  }

  async signIn(email: string, password: string): Promise<string | null> {
    const { error } = await this.supabase.auth.signInWithPassword({ email, password });
    return error ? translate(error) : null;
  }

  /**
   * Crea la cuenta. El perfil y la aceptación del aviso de privacidad los crea la
   * base de datos (trigger handle_new_user) con los datos enviados aquí.
   */
  async signUp(data: SignUpData): Promise<{ error: string | null; needsConfirmation: boolean }> {
    const { data: result, error } = await this.supabase.auth.signUp({
      email: data.email,
      password: data.password,
      options: {
        emailRedirectTo: `${location.origin}/inicio`,
        data: {
          full_name: data.fullName.trim(),
          birth_date: data.birthDate,
          institution: data.institution.trim(),
          academic_level: data.academicLevel,
          privacy_notice_version: PRIVACY_NOTICE_VERSION,
        },
      },
    });
    if (error) return { error: translate(error), needsConfirmation: false };
    return { error: null, needsConfirmation: result.session === null };
  }

  async signOut(): Promise<void> {
    await this.supabase.auth.signOut();
    this.profile.set(null);
  }

  private async restoreSession(): Promise<void> {
    const { data } = await this.supabase.auth.getSession();
    this.session.set(data.session);
    await this.loadProfile();
  }

  private async loadProfile(): Promise<void> {
    const userId = this.session()?.user.id;
    if (!userId) {
      this.profile.set(null);
      return;
    }

    const { data } = await this.supabase
      .from('profiles')
      .select('id, full_name, birth_date, institution, academic_level, roles(name)')
      .eq('id', userId)
      .maybeSingle();

    this.profile.set(
      data
        ? {
            id: data.id,
            fullName: data.full_name,
            birthDate: data.birth_date,
            institution: data.institution,
            academicLevel: data.academic_level,
            role: (data.roles as unknown as { name: RoleName } | null)?.name ?? 'student',
          }
        : null,
    );
  }
}
