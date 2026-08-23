async function login(email, password) {
  const { data, error } = await supabaseClient.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    throw error;
  }

  return data;
}

async function logout() {
  const { error } = await supabaseClient.auth.signOut();

  if (error) {
    throw error;
  }

  window.location.href = "/login.html";
}

async function getCurrentSession() {
  const {
    data: { session },
    error,
  } = await supabaseClient.auth.getSession();

  if (error) {
    throw error;
  }

  return session;
}

async function getAuthorizedUser() {
  const session = await getCurrentSession();

  if (!session) {
    return null;
  }

  const { data, error } = await supabaseClient
    .from("usuarios_app")
    .select("user_id, email, nombre, rol, activo")
    .eq("user_id", session.user.id)
    .eq("activo", true)
    .single();

  if (error) {
    console.error("Error buscando usuario autorizado:", error);
    return null;
  }

  return data;
}