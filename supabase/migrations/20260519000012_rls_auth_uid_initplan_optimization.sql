-- Supabase advisor "auth_rls_initplan" warning: auth.uid() / auth.jwt()
-- inside a USING / WITH CHECK clause is re-evaluated per candidate row.
-- Wrapping the call in `(SELECT auth.uid())` lets Postgres treat it as a
-- stable subquery initplan and evaluate once per statement. Behavior is
-- identical; the speed-up matters at scale.

DROP POLICY IF EXISTS users_select ON public.users;
CREATE POLICY users_select ON public.users
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    auth_user_id = (SELECT auth.uid())
    OR id IN (
      SELECT ou.user_id FROM public.organization_users ou
      WHERE ou.organization_id = public.current_org()
        AND ou.status = 'ACTIVE'
        AND ou.deleted_at IS NULL
    )
  );

DROP POLICY IF EXISTS users_update_self ON public.users;
CREATE POLICY users_update_self ON public.users
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (auth_user_id = (SELECT auth.uid()))
  WITH CHECK (auth_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS organization_invitations_select ON public.organization_invitations;
CREATE POLICY organization_invitations_select ON public.organization_invitations
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    OR email = ((SELECT auth.jwt()) ->> 'email')
  );
