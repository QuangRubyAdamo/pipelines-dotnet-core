# Multi-stage build: compile with the .NET SDK, run on the smaller ASP.NET runtime.
# Keep both tags on the same major version as <TargetFramework> in the .csproj.
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src
COPY pipelines-dotnet-core.csproj ./
RUN dotnet restore pipelines-dotnet-core.csproj
COPY . ./
RUN dotnet publish pipelines-dotnet-core.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS runtime
# The 6.0 images run as root and listen on :80 by default; use an unprivileged user and port.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /app ./
ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_PRINT_TELEMETRY_MESSAGE=false
EXPOSE 8080
USER 10001
ENTRYPOINT ["dotnet", "pipelines-dotnet-core.dll"]
