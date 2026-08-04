using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using GatewayService.Data;
using GatewayService.Models;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection");
builder.Services.AddDbContext<AppDbContext>(options =>
		options.UseMySql(connectionString, ServerVersion.AutoDetect(connectionString)));

builder.Services.AddOpenApi();
builder.Services.AddCors(options => {
		options.AddDefaultPolicy(policy =>
				policy.AllowAnyOrigin().AllowAnyMethod().AllowAnyHeader());
});

var app = builder.Build();

if (app.Environment.IsDevelopment()) {
	app.MapOpenApi();
}

app.UseCors();
app.UseWebSockets();

var activeSockets = new List<WebSocket>();
var socketLock = new object();

app.Use(async (context, next) => {
	if (context.Request.Path == "/ws") {
		if (context.WebSockets.IsWebSocketRequest) {
			using var webSocket = await context.WebSockets.AcceptWebSocketAsync();
			lock (socketLock) { activeSockets.Add(webSocket); }

			app.Logger.LogInformation("[Gateway] New WebSocket client Connected.");

			var buffer = new byte[1024 * 4];
			while (webSocket.State == WebSocketState.Open) {
			var result = await webSocket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
			if (result.MessageType == WebSocketMessageType.Close) {
				await webSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closing", CancellationToken.None);
				}
			}

			lock (socketLock) { activeSockets.Remove(webSocket); }
			app.Logger.LogInformation("[Gateway] WebSocket client disconnected.");
		} else {
			context.Response.StatusCode = StatusCodes.Status400BadRequest;
		}
	} else {
		await next(context);
	}
});

app.MapPost("/api/attractors", async (AttractorDto dto, AppDbContext db) => {
	var entity = new Attractor {
		FormulaLatex = dto.FormulaLatex,
		RSquared = dto.RSquared,
		IsStable = dto.RSquared >= 0.20f,
		CreatedAt = DateTime.UtcNow
	};

	db.Attractors.Add(entity);
	await db.SaveChangesAsync();

	var payload = JsonSerializer.Serialize(new {
		type = "ATTRACTOR_UPDATED",
		data = entity
	});
	var bytes = Encoding.UTF8.GetBytes(payload);

	List<WebSocket> targets;
	lock (socketLock) { targets = activeSockets.Where(s => s.State == WebSocketState.Open).ToList(); }

	foreach (var socket in targets) {
		await socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
	}

	return Results.Created($"/api/attractors/{entity.Id}", entity);
});

app.MapGet("/api/attractors", async (AppDbContext db) => {
	return await db.Attractors
		.OrderByDescending(a => a.CreatedAt)
		.Take(50)
		.ToListAsync();
});

app.Run();

record AttractorDto(string FormulaLatex, float RSquared);



