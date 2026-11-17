import { Component, inject } from '@angular/core';
import { RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { PRIVACY_NOTICE_VERSION } from '../../core/supabase/supabase.config';

/** Aviso de privacidad (versión preliminar, pendiente de revisión del equipo). */
@Component({
  imports: [RouterLink],
  templateUrl: './privacy.page.html',
})
export class PrivacyPage {
  protected readonly version = PRIVACY_NOTICE_VERSION;
  protected readonly loggedIn = inject(AuthService).isLoggedIn;
}
