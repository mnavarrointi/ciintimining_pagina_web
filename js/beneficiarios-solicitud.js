(function () {
  "use strict";

  let modalOverlay = null;

  function escapeHtml(value) {
    return String(value ?? "").replace(
      /[&<>"']/g,
      (character) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#039;",
        })[character]
    );
  }

  function insertarEstilos() {
    if (document.getElementById("beneficiaryCreateStyles")) return;

    const style = document.createElement("style");
    style.id = "beneficiaryCreateStyles";

    style.textContent = `
      .beneficiary-inline-row {
        display: flex;
        gap: 8px;
        align-items: center;
      }

      .beneficiary-inline-row select {
        flex: 1;
      }

      .beneficiary-create-button {
        white-space: nowrap;
        background: #eeeeee;
        color: #222222;
      }

      .beneficiary-helper {
        margin-top: 6px;
        color: #666666;
        font-size: 12px;
      }

      .beneficiary-modal-overlay {
        position: fixed;
        inset: 0;
        z-index: 10000;
        display: none;
        align-items: center;
        justify-content: center;
        padding: 20px;
        background: rgba(0, 0, 0, 0.48);
      }

      .beneficiary-modal {
        width: min(620px, 100%);
        max-height: 90vh;
        overflow-y: auto;
        background: white;
        border-radius: 12px;
        padding: 24px;
        box-shadow: 0 20px 55px rgba(0, 0, 0, 0.25);
      }

      .beneficiary-modal-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 16px;
        margin-bottom: 20px;
      }

      .beneficiary-modal-header h2 {
        margin: 0 0 5px;
      }

      .beneficiary-close-button {
        background: #eeeeee;
        font-size: 18px;
        line-height: 1;
      }

      .beneficiary-form-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 16px;
      }

      .beneficiary-field-full {
        grid-column: 1 / -1;
      }

      .beneficiary-form-grid label {
        display: block;
        margin-bottom: 6px;
        font-weight: 600;
      }

      .beneficiary-form-grid input,
      .beneficiary-form-grid select {
        width: 100%;
        box-sizing: border-box;
        padding: 10px;
        border: 1px solid #cccccc;
        border-radius: 6px;
        background: white;
      }

      .beneficiary-modal-actions {
        display: flex;
        justify-content: flex-end;
        gap: 10px;
        margin-top: 20px;
      }

      .beneficiary-primary-button {
        background: #222222;
        color: white;
      }

      .beneficiary-secondary-button {
        background: #eeeeee;
        color: #222222;
      }

      .beneficiary-message {
        margin-top: 15px;
      }

      .beneficiary-success,
      .beneficiary-warning,
      .beneficiary-error {
        padding: 12px;
        border-radius: 7px;
      }

      .beneficiary-success {
        background: #eef8ee;
      }

      .beneficiary-warning {
        background: #fff5d6;
      }

      .beneficiary-error {
        background: #ffeaea;
      }

      @media (max-width: 650px) {
        .beneficiary-inline-row {
          align-items: stretch;
          flex-direction: column;
        }

        .beneficiary-form-grid {
          grid-template-columns: 1fr;
        }

        .beneficiary-field-full {
          grid-column: auto;
        }
      }
    `;

    document.head.appendChild(style);
  }

  function crearModal() {
    if (document.getElementById("newBeneficiaryPaymentModal")) {
      modalOverlay = document.getElementById(
        "newBeneficiaryPaymentModal"
      );
      return;
    }

    modalOverlay = document.createElement("div");

    modalOverlay.id = "newBeneficiaryPaymentModal";
    modalOverlay.className = "beneficiary-modal-overlay";

    modalOverlay.innerHTML = `
      <div class="beneficiary-modal">

        <div class="beneficiary-modal-header">

          <div>
            <h2>Nuevo beneficiario</h2>

            <div style="color:#666;">
              Antes de crear el registro, el sistema verificará
              si ya existe.
            </div>
          </div>

          <button
            type="button"
            id="closeNewBeneficiaryPaymentModal"
            class="beneficiary-close-button"
          >
            ×
          </button>

        </div>

        <form id="newBeneficiaryPaymentForm">

          <div class="beneficiary-form-grid">

            <div class="beneficiary-field-full">

              <label>Nombre *</label>

              <input
                type="text"
                id="newPaymentBeneficiaryName"
                required
                placeholder="Nombre o razón social"
              >

            </div>

            <div>

              <label>Tipo *</label>

              <select
                id="newPaymentBeneficiaryType"
                required
              >
                <option value="PROVEEDOR">
                  Proveedor
                </option>

                <option value="EMPLEADO">
                  Empleado
                </option>

                <option value="ENTIDAD_GOBIERNO">
                  Entidad de Gobierno
                </option>

                <option value="BANCO">
                  Banco
                </option>

                <option value="CLIENTE">
                  Cliente
                </option>

                <option value="OTRO">
                  Otro
                </option>
              </select>

            </div>

            <div>

              <label>País</label>

              <select id="newPaymentBeneficiaryCountry">

                <option value="">
                  Sin especificar
                </option>

                <option value="CO">
                  Colombia
                </option>

                <option value="PE">
                  Perú
                </option>

                <option value="US">
                  Estados Unidos
                </option>

              </select>

            </div>

            <div class="beneficiary-field-full">

              <label>Identificación</label>

              <input
                type="text"
                id="newPaymentBeneficiaryIdentification"
                placeholder="NIT, RUC, documento, EIN, etc."
              >

              <div class="beneficiary-helper">
                Si conoces la identificación, ingrésala.
                Ayuda a evitar beneficiarios duplicados.
              </div>

            </div>

          </div>

          <div
            id="newPaymentBeneficiaryMessage"
            class="beneficiary-message"
          ></div>

          <div class="beneficiary-modal-actions">

            <button
              type="button"
              id="cancelNewBeneficiaryPayment"
              class="beneficiary-secondary-button"
            >
              Cancelar
            </button>

            <button
              type="submit"
              id="saveNewBeneficiaryPayment"
              class="beneficiary-primary-button"
            >
              Verificar y crear
            </button>

          </div>

        </form>

      </div>
    `;

    document.body.appendChild(modalOverlay);

    document
      .getElementById("closeNewBeneficiaryPaymentModal")
      .addEventListener("click", cerrarModal);

    document
      .getElementById("cancelNewBeneficiaryPayment")
      .addEventListener("click", cerrarModal);

    modalOverlay.addEventListener("click", (event) => {
      if (event.target === modalOverlay) {
        cerrarModal();
      }
    });

    document
      .getElementById("newBeneficiaryPaymentForm")
      .addEventListener(
        "submit",
        guardarBeneficiario
      );
  }

  function abrirModal() {
    if (!modalOverlay) {
      crearModal();
    }

    document
      .getElementById("newBeneficiaryPaymentForm")
      .reset();

    document
      .getElementById("newPaymentBeneficiaryMessage")
      .innerHTML = "";

    modalOverlay.style.display = "flex";

    setTimeout(() => {
      document
        .getElementById("newPaymentBeneficiaryName")
        ?.focus();
    }, 50);
  }

  function cerrarModal() {
    if (!modalOverlay) return;

    modalOverlay.style.display = "none";

    const form = document.getElementById(
      "newBeneficiaryPaymentForm"
    );

    if (form) {
      form.reset();
    }

    const message = document.getElementById(
      "newPaymentBeneficiaryMessage"
    );

    if (message) {
      message.innerHTML = "";
    }
  }

  async function recargarBeneficiarios(
    seleccionarId = null
  ) {
    const select = document.getElementById(
      "beneficiarioId"
    );

    if (!select) {
      throw new Error(
        "No se encontró el selector de beneficiarios."
      );
    }

    const { data, error } = await supabaseClient
      .from("beneficiarios")
      .select("id, nombre")
      .eq("activo", true)
      .order("nombre");

    if (error) {
      throw error;
    }

    select.innerHTML = "";

    const placeholder =
      document.createElement("option");

    placeholder.value = "";
    placeholder.textContent =
      "Seleccionar beneficiario";

    select.appendChild(placeholder);

    (data || []).forEach((beneficiario) => {
      const option =
        document.createElement("option");

      option.value = beneficiario.id;
      option.textContent = beneficiario.nombre;

      select.appendChild(option);
    });

    if (seleccionarId) {
      select.value = seleccionarId;
    }
  }

  async function guardarBeneficiario(event) {
    event.preventDefault();

    const nombre = document
      .getElementById("newPaymentBeneficiaryName")
      .value
      .trim();

    const tipo = document
      .getElementById("newPaymentBeneficiaryType")
      .value;

    const identificacion = document
      .getElementById(
        "newPaymentBeneficiaryIdentification"
      )
      .value
      .trim();

    const pais = document
      .getElementById(
        "newPaymentBeneficiaryCountry"
      )
      .value;

    const message = document.getElementById(
      "newPaymentBeneficiaryMessage"
    );

    const button = document.getElementById(
      "saveNewBeneficiaryPayment"
    );

    if (!nombre) {
      message.innerHTML = `
        <div class="beneficiary-error">
          El nombre es obligatorio.
        </div>
      `;

      return;
    }

    button.disabled = true;
    button.textContent = "Verificando...";

    message.innerHTML = "";

    try {
      const { data, error } =
        await supabaseClient.rpc(
          "crear_beneficiario_validado",
          {
            p_nombre: nombre,
            p_tipo: tipo,
            p_identificacion:
              identificacion || null,
            p_pais:
              pais || null,
          }
        );

      if (error) {
        throw error;
      }

      const beneficiarioId =
        data?.beneficiario_id;

      if (!beneficiarioId) {
        throw new Error(
          "La base no devolvió el identificador del beneficiario."
        );
      }

      await recargarBeneficiarios(
        beneficiarioId
      );

      if (data?.duplicado) {
        message.innerHTML = `
          <div class="beneficiary-warning">

            Ya existe un beneficiario coincidente:

            <strong>
              ${escapeHtml(data.nombre)}
            </strong>.

            <br><br>

            No se creó un duplicado.
            Se seleccionó el registro existente.

          </div>
        `;
      } else {
        message.innerHTML = `
          <div class="beneficiary-success">

            Beneficiario creado correctamente:

            <strong>
              ${escapeHtml(data.nombre)}
            </strong>.

            <br><br>

            Ya quedó seleccionado en el pago
            que estás creando.

          </div>
        `;
      }

      setTimeout(() => {
        cerrarModal();
      }, 1100);

    } catch (error) {
      console.error(
        "Error creando beneficiario:",
        error
      );

      message.innerHTML = `
        <div class="beneficiary-error">
          ${escapeHtml(
            error.message || error
          )}
        </div>
      `;

    } finally {
      button.disabled = false;

      button.textContent =
        "Verificar y crear";
    }
  }

  function instalarBoton() {
    const select = document.getElementById(
      "beneficiarioId"
    );

    if (!select) {
      console.warn(
        "No se encontró #beneficiarioId. " +
        "No se instaló el creador de beneficiarios."
      );

      return;
    }

    if (
      document.getElementById(
        "openNewBeneficiaryFromPayment"
      )
    ) {
      return;
    }

    insertarEstilos();
    crearModal();

    const parent = select.parentElement;

    const row =
      document.createElement("div");

    row.className =
      "beneficiary-inline-row";

    parent.insertBefore(
      row,
      select
    );

    row.appendChild(select);

    const button =
      document.createElement("button");

    button.type = "button";

    button.id =
      "openNewBeneficiaryFromPayment";

    button.className =
      "beneficiary-create-button";

    button.textContent =
      "+ Nuevo";

    button.addEventListener(
      "click",
      abrirModal
    );

    row.appendChild(button);

    const helper =
      document.createElement("div");

    helper.className =
      "beneficiary-helper";

    helper.textContent =
      "Si el beneficiario no existe, " +
      "créalo aquí sin salir de la solicitud.";

    row.insertAdjacentElement(
      "afterend",
      helper
    );
  }

  if (
    document.readyState === "loading"
  ) {
    document.addEventListener(
      "DOMContentLoaded",
      instalarBoton
    );
  } else {
    instalarBoton();
  }
})();