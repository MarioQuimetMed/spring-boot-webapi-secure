# Policy as Code para el Dockerfile del proyecto (Conftest / OPA).
# Uso: conftest test Dockerfile --policy policy --output json
package main

import rego.v1

# Conftest entrega el Dockerfile como lista de instrucciones ({Cmd, Value, Stage})
cmds := input

froms := [c | some c in cmds; c.Cmd == "from"]

last_stage := max({c.Stage | some c in cmds})

runtime_image := froms[count(froms) - 1].Value[0]

# 1. Imagenes base con tag fijo (sin tag o :latest = build no reproducible)
deny contains msg if {
	some c in froms
	image := c.Value[0]
	not contains(image, ":")
	msg := sprintf("La imagen base '%s' no tiene tag fijo", [image])
}

deny contains msg if {
	some c in froms
	endswith(c.Value[0], ":latest")
	msg := sprintf("La imagen base '%s' usa el tag latest", [c.Value[0]])
}

# 2. El runtime no debe incluir el JDK completo (mas paquetes = mas superficie de ataque)
deny contains msg if {
	contains(runtime_image, "jdk")
	msg := sprintf("La imagen de runtime '%s' incluye el JDK completo; usar una imagen JRE", [runtime_image])
}

# 3. El contenedor no debe ejecutarse como root
runtime_users := [c.Value[0] | some c in cmds; c.Cmd == "user"; c.Stage == last_stage]

deny contains msg if {
	count(runtime_users) == 0
	msg := "La etapa final no define USER: el contenedor se ejecuta como root"
}

deny contains msg if {
	some u in runtime_users
	startswith(u, "root")
	msg := "La etapa final se ejecuta como root (USER root)"
}

# 4. Recomendado: HEALTHCHECK para que el orquestador detecte la app caida
warn contains msg if {
	not any_healthcheck
	msg := "El Dockerfile no define HEALTHCHECK"
}

any_healthcheck if {
	some c in cmds
	c.Cmd == "healthcheck"
}
