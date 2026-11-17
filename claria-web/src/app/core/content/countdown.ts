import { DestroyRef, computed, inject, signal } from '@angular/core';

/**
 * Cuenta regresiva en segundos para los tiempos mínimos de lecciones y juegos.
 * El valor inicial lo da el servidor; aquí solo se muestra el avance.
 * Debe crearse en un contexto de inyección (p. ej. como campo de un componente).
 */
export function createCountdown() {
  const remaining = signal(0);
  let timer: ReturnType<typeof setInterval> | undefined;

  inject(DestroyRef).onDestroy(() => clearInterval(timer));

  return {
    remaining: remaining.asReadonly(),
    /** "0:42" */
    label: computed(() => {
      const s = Math.max(0, remaining());
      return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    }),
    start(seconds: number): void {
      clearInterval(timer);
      remaining.set(Math.max(0, seconds));
      if (seconds <= 0) return;
      timer = setInterval(() => {
        remaining.update((s) => s - 1);
        if (remaining() <= 0) clearInterval(timer);
      }, 1000);
    },
  };
}
