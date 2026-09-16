import type { RequestHandler } from './$types';
import { submitSupport } from '$lib/server/support-intake';

export const prerender = false;
export const POST: RequestHandler = ({ request, platform, getClientAddress }) =>
  submitSupport(request, platform?.env, getClientAddress());
