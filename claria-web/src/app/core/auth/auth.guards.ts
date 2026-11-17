import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';

import { AuthService } from './auth.service';

/** Solo deja pasar con sesión iniciada; si no, manda a /ingresar. */
export const authGuard: CanActivateFn = async () => {
  // inject() solo funciona antes del primer await.
  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.ready;
  return auth.isLoggedIn() || router.createUrlTree(['/ingresar']);
};

/** Las páginas de ingreso y registro no tienen sentido con sesión: manda a /inicio. */
export const guestGuard: CanActivateFn = async () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.ready;
  return !auth.isLoggedIn() || router.createUrlTree(['/inicio']);
};

/** Solo docentes y administradores (p. ej. la revisión de intentos). */
export const staffGuard: CanActivateFn = async () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.ready;
  // El perfil se carga después de la sesión: se espera un momento si aún no llega.
  for (let i = 0; i < 20 && auth.isLoggedIn() && !auth.profile(); i++) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return auth.isStaff() || router.createUrlTree(['/evaluador']);
};
