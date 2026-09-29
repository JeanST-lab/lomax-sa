class ErrorPaso(Exception):
    """Error HTTP que identifica el paso fallido.

    Cuerpo de respuesta:
    {"error": {"paso": "...", "detalle": "..."}, "producto_id": "...", "estado": "..."}
    """

    def __init__(self, status, paso, detalle, producto_id=None, estado=None):
        super().__init__(str(detalle))
        self.status = status
        self.paso = paso
        self.detalle = str(detalle)[:500]
        self.producto_id = producto_id
        self.estado = estado

    def cuerpo(self):
        cuerpo = {"error": {"paso": self.paso, "detalle": self.detalle}}
        if self.producto_id:
            cuerpo["producto_id"] = self.producto_id
        if self.estado:
            cuerpo["estado"] = self.estado
        return cuerpo
