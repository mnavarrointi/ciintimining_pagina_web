// Elementos principales
const menuButton = document.getElementById("menuButton");
const navigation = document.getElementById("mainNavigation");
const navigationLinks = navigation.querySelectorAll("a");

const platformButton = document.getElementById("platformButton");

const contactForm = document.getElementById("contactForm");
const formMessage = document.getElementById("formMessage");

const currentYear = document.getElementById("currentYear");


// Mostrar el año actual en el pie de página
currentYear.textContent = new Date().getFullYear();


// Abrir y cerrar menú móvil
menuButton.addEventListener("click", () => {
    const isOpen = navigation.classList.toggle("is-open");

    menuButton.setAttribute("aria-expanded", isOpen.toString());

    document.body.classList.toggle("menu-open", isOpen);
});


// Cerrar el menú cuando se selecciona un enlace
navigationLinks.forEach((link) => {
    link.addEventListener("click", () => {
        navigation.classList.remove("is-open");
        menuButton.setAttribute("aria-expanded", "false");
        document.body.classList.remove("menu-open");
    });
});


// Botón temporal de acceso a plataforma
platformButton.addEventListener("click", (event) => {
    event.preventDefault();

    window.alert(
        "La plataforma documental de CI Inti Mining estará disponible próximamente."
    );
});


// Formulario temporal
contactForm.addEventListener("submit", (event) => {
    event.preventDefault();

    const formData = new FormData(contactForm);

    const name = formData.get("name").trim();
    const email = formData.get("email").trim();
    const message = formData.get("message").trim();

    if (!name || !email || !message) {
        formMessage.textContent =
            "Por favor, complete los campos obligatorios.";

        return;
    }

    formMessage.textContent =
        `Gracias, ${name}. Su solicitud fue preparada correctamente.`;

    /*
        En esta versión estática el formulario todavía no envía
        información a un servidor.

        Más adelante podemos conectarlo gratuitamente con:
        - Supabase
        - Un correo corporativo
        - Una función de Cloudflare
    */

    contactForm.reset();
});