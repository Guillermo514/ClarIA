import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

import { AuthService } from './core/auth/auth.service';
import { ContentService } from './core/content/content.service';

import { SIDEBAR_SECTIONS, TOP_NAV_LINKS } from './core/navigation/navigation';

const THEME_STORAGE_KEY = 'claria-theme';

/**
 * Shell de la aplicación: barra superior, menú lateral y modal de auditoría.
 * Sin sesión (ingreso, registro, aviso de privacidad) solo se muestra la página.
 * Los estilos viven en `src/styles/layout.css`.
 */
@Component({
  selector: 'app-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive],
  templateUrl: './app.html',
})
export class App implements OnInit {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);

  protected readonly loggedIn = this.auth.isLoggedIn;
  protected readonly displayName = this.auth.displayName;
  protected readonly initials = this.auth.initials;
  protected readonly currentLevel = inject(ContentService).currentLevel;

  protected readonly topLinks = TOP_NAV_LINKS;
  protected readonly sidebarSections = SIDEBAR_SECTIONS;

  protected readonly sidebarOpen = signal(true);
  protected readonly dark = signal(true);
  protected readonly profileOpen = signal(false);
  protected readonly auditOpen = signal(false);

  protected readonly themeLabel = computed(() =>
    this.dark() ? 'Cambiar a tema claro' : 'Cambiar a tema oscuro',
  );

  ngOnInit(): void {
    const saved = localStorage.getItem(THEME_STORAGE_KEY);
    this.dark.set(saved !== 'light');
    document.documentElement.classList.toggle('light', saved === 'light');
  }

  protected toggleSidebar(): void {
    this.sidebarOpen.update((open) => !open);
  }

  protected toggleProfile(): void {
    this.profileOpen.update((open) => !open);
  }

  protected async signOut(): Promise<void> {
    this.profileOpen.set(false);
    await this.auth.signOut();
    await this.router.navigateByUrl('/ingresar');
  }

  protected toggleTheme(): void {
    this.dark.update((dark) => !dark);
    const light = !this.dark();
    document.documentElement.classList.toggle('light', light);
    localStorage.setItem(THEME_STORAGE_KEY, light ? 'light' : 'dark');
  }
}
